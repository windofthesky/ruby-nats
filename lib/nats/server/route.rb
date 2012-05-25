module NATSD #:nodoc: all

  module Route #:nodoc:

    include Connection

    attr_reader :rid, :closing, :r_obj
    alias :peer_info :client_info

    def initialize(route=nil)
      @r_obj = route
    end

    def solicited?
      r_obj != nil
    end

    def post_init
      @rid = Server.rid
      @subscriptions = {}
      @in_msgs = @out_msgs = @in_bytes = @out_bytes = 0
      @writev_size = 0
      @parse_state = AWAITING_CONTROL_LINE

      # queue up auth if needed and we solicited the connection
      if solicited?
        send_auth
      else
        # FIXME, separate variables for timeout?
        @auth_pending = EM.add_timer(NATSD::Server.auth_timeout) { connect_auth_timeout } if Server.route_auth_required?
      end

      send_info
      debug "#{type} connection created", peer_info, rid
      @ping_timer = EM.add_periodic_timer(NATSD::Server.ping_interval) { send_ping }
      @pings_outstanding = 0
      inc_connections
    end

    def receive_data(data)
      @buf = @buf ? @buf << data : data
      return close_connection if @buf =~ /(\006|\004)/ # ctrl+c or ctrl+d for telnet friendly

      while (@buf && !@closing)
        case @parse_state
        when AWAITING_CONTROL_LINE
          case @buf
          when MSG
            ctrace('MSG OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            @parse_state = AWAITING_MSG_PAYLOAD
            @msg_sub, @msg_sid, @msg_reply, @msg_size = $1, $2, $4, $5.to_i
            if (@msg_size > NATSD::Server.max_payload)
              debug_print_msg_too_big(@msg_size)
              error_close PAYLOAD_TOO_BIG
            end
            queue_data(INVALID_SUBJECT) if (@pedantic && !(@msg_sub =~ SUB_NO_WC))
          when SUB_OP
            ctrace('SUB OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            sub, qgroup, sid = $1, $3, $4
            return queue_data(INVALID_SUBJECT) if !($1 =~ SUB)
            return queue_data(INVALID_SID_TAKEN) if @subscriptions[sid]
            sub = Subscriber.new(self, sub, sid, qgroup, 0)
            @subscriptions[sid] = sub
            Server.subscribe(sub, is_route?)
            queue_data(OK) if @verbose
          when UNSUB_OP
            ctrace('UNSUB OP', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            sid, sub = $1, @subscriptions[$1]
            if sub
              # If we have set max_responses, we will unsubscribe once we have received
              # the appropriate amount of responses.
              sub.max_responses = ($2 && $3) ? $3.to_i : nil
              delete_subscriber(sub) unless (sub.max_responses && (sub.num_responses < sub.max_responses))
              queue_data(OK) if @verbose
            else
              queue_data(INVALID_SID_NOEXIST) if @pedantic
            end
          when PING
            ctrace('PING OP') if NATSD::Server.trace_flag?
            @buf = $'
            queue_data(PONG_RESPONSE)
            flush_data
          when PONG
            ctrace('PONG OP') if NATSD::Server.trace_flag?
            @buf = $'
            @pings_outstanding -= 1
          when CONNECT
            ctrace('CONNECT OP', strip_op($&)) if NATSD::Server.trace_flag?
            @buf = $'
            begin
              config = JSON.parse($1)
              process_connect_config(config)
            rescue => e
              queue_data(INVALID_CONFIG)
              log_error
            end
          when INFO_REQ
            ctrace('INFO_REQUEST OP') if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            send_info
          when INFO
            return connect_auth_timeout if @auth_pending
            @buf = $'
            process_info($1)
          when ERR_RESP
            ctrace('-ERR', $1) if NATSD::Server.trace_flag?
            close_connection
            exit
          when OK_RESP
            ctrace('+OK') if NATSD::Server.trace_flag?
            @buf = $'
          when UNKNOWN
            ctrace('Unknown Op', strip_op($&)) if NATSD::Server.trace_flag?
            return connect_auth_timeout if @auth_pending
            @buf = $'
            queue_data(UNKNOWN_OP)
          else
            # If we are here we do not have a complete line yet that we understand.
            # If too big, cut the connection off.
            if @buf.bytesize > NATSD::Server.max_control_line
              debug_print_controlline_too_big(@buf.bytesize)
              close_connection
            end
            return
          end
          @buf = nil if (@buf && @buf.empty?)

        when AWAITING_MSG_PAYLOAD
          return unless (@buf.bytesize >= (@msg_size + CR_LF_SIZE))
          msg = @buf.slice(0, @msg_size)

          ctrace('Processing routed msg', @msg_sub, @msg_reply, msg) if NATSD::Server.trace_flag?
          queue_data(OK) if @verbose

          # We deliver normal subscriptions like a client publish, which
          # eliminates the duplicate traversal over the route. However,
          # qgroups are sent individually per group for only the route
          # with the intended subscriber, since route interest is L2
          # semantics, we deliver those direct.
          if (sub = Server.rsid_qsub(@msg_sid))
            Server.deliver_to_subscriber(sub, @msg_sub, @msg_reply, msg)
          else
            Server.route_to_subscribers(@msg_sub, @msg_reply, msg, is_route?)
          end

          @in_msgs += 1
          @in_bytes += @msg_size
          @buf = @buf.slice((@msg_size + CR_LF_SIZE), @buf.bytesize)
          @msg_sub = @msg_size = @reply = nil
          @parse_state = AWAITING_CONTROL_LINE
          @buf = nil if (@buf && @buf.empty?)
        end
      end
    end

    def send_auth
      return unless r_obj[:uri].user
      cs = { :user => r_obj[:uri].user, :pass => r_obj[:uri].password }
      queue_data("CONNECT #{cs.to_json}#{CR_LF}")
    end

    def send_info
      queue_data("INFO #{Server.route_info_string}#{CR_LF}")
    end

    def process_info(info)
      super(info)
    end

    def auth_ok?(user, pass)
      Server.route_auth_ok?(user, pass)
    end

    def inc_connections
      Server.num_routes += 1
      Server.add_route(self)
    end

    def dec_connections
      Server.num_routes -= 1
      Server.remove_route(self)
    end

    def ctrace(*args)
      trace(args, "r: #{rid}")
    end

    def is_route?
      true
    end

    def type
      'Route'
    end

  end

end