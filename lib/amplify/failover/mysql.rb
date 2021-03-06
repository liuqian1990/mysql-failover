# coding: utf-8

require 'sequel'
require 'logger'
require 'jdbc/mysql'

module Amplify
  module Failover
    class MySQLWatchdog < Watchdog
      attr_reader :status, :active_master_id

      def initialize(mysql_cfg, zk_cfg, misc_cfg = {})
        @watcher_server_id      = normalize_server_id(zk_cfg['server_id'])
        @active_master_id_znode = zk_cfg['active_master_id_znode']    || '/active_master_id'
        @state_znode            = zk_cfg['state_znode']               || '/state'
        @client_data_znode      = zk_cfg['client_data_znode']         || '/client_data'
        @tracking_max_wait_secs = mysql_cfg['tracking_max_wait_secs'] || 600
        @client_data            = mysql_cfg['client_data']
        @tracking_poll_interval_secs = mysql_cfg['tracking_poll_interval_secs'] || 5
        @migrations_dir         = mysql_cfg['migrations_dir'] || 'db/migrate'

        super(zk_cfg, misc_cfg)

        mysql_connect mysql_cfg
      end

      def step_up(meta)
        @graphite.send_metrics("#{@watcher_server_id}.step_up" => 1)
        @logger.info 'This server will become the active master.'

        state = failover_state
        if state != Amplify::Failover::STATE_COMPLETE
          @logger.warn "Transition currently in progress. " \
                       "Not processing second transition. " \
                       "#{@active_master_id_znode} may be incorrect."
          @logger.debug "Current state: #{state}"
          return false
        end

        state_change do |local_state|
          mysql_read_only false
          mysql_poll_for_tracker meta
          set_client_data
        end
      end

      def step_down(meta)
        @graphite.send_metrics("#{@watcher_server_id}.step_down" => 1)
        @logger.info 'This server will become the passive master.'
        mysql_read_only
        mysql_kill_connections
        mysql_insert_tracker meta
        @logger.info 'Now in passive mode.'
      end

      def mysql_connect(mysql_cfg)
        Jdbc::MySQL.load_driver
        @db = Sequel.connect(adapter:        'jdbc',
                             uri:            mysql_cfg['uri'],
                             user:           mysql_cfg['user'],
                             password:       mysql_cfg['password'],
                             sql_log_level:  :debug,
                             logger:         @logger)

        # rubocop:disable LineLength
        # http://sequel.jeremyevans.net/rdoc-plugins/files/lib/sequel/extensions/connection_validator_rb.html
        # This extension checks the validity of a connection before querying.
        # This is here to avoid having to explicitly reconnect every time a query is executed
        # it isn't free, but this service only does a handful of queries
        # rubocop:enable LineLength

        @db.extension(:connection_validator)

        @db.pool.connection_validation_timeout = -1
        run_sequel_migrations
      end

      def mysql_connected?
        @db['select 1'].all
        true
      rescue
        false
      end

      def run_sequel_migrations
        # make sure only one node is running these
        lock = @zk.exclusive_locker('migrations_running')

        unless lock.lock(wait: false)
          @logger.info 'Another node is running database migrations.  Skipping.'
          return
        end

        begin
          Sequel.extension :migration

          unless Sequel::Migrator.is_current?(@db, @migrations_dir)
            Sequel::Migrator.run(@db, @migrations_dir)
            @graphite.send_metrics("#{@watcher_server_id}.migrations_run" => 1)
          end
        rescue => e
          @logger.error "Error running migrations: #{e}"
        ensure
          lock.unlock
        end
      end

      def background!
        super 'mysql-master-watcher'
      end

      def process_queue_event(type, value, meta)
        case type
        when :active_master_changed
          process_master_change(value, meta)
        end
      end

    # Public: Does this server need to step up to active master?
      def step_up?(new_active_server_id)
        # if this server was not the active master and now has become the active master, step up
        @logger.debug "in step_up?: new_active_server_id: #{new_active_server_id}," \
                      "@watcher_server_id: #{@watcher_server_id}, " \
                      "@active_master_id: #{@active_master_id}"
        @active_master_id != @watcher_server_id && new_active_server_id == @watcher_server_id
      end

    # Public: Does this server need to step down from active master?
      def step_down?(new_active_server_id)
        # if this server was the active master and is no longer the active master, step down
        @active_master_id == @watcher_server_id && new_active_server_id != @watcher_server_id
      end

      def process_master_change(new_active_server_id, meta)
        # do nothing if the value didn't actually change (for znode version changes)
        return if normalize_server_id(new_active_server_id) == active_master_id

        if step_up?(new_active_server_id)
          @active_master_id = new_active_server_id
          @graphite.send_timer("#{@watcher_server_id}.step_up_secs") do
            step_up(meta)
          end

        elsif step_down?(new_active_server_id)
          @active_master_id = new_active_server_id
          @graphite.send_timer("#{@watcher_server_id}.step_down_secs") do
            step_down(meta)
          end
        end
      end

      def failover_state
        @zk.get(@state_znode).first
      rescue ZK::Exceptions::NoNode
        # if this node doesn't exist, then failover has never occurred, so it should be
        # in the complete state
        Amplify::Failover::STATE_COMPLETE
      end

      def state_change
        @zk.create(@state_znode, Amplify::Failover::STATE_TRANSITION, or: :set, mode: :persistent)
        @graphite.send_metrics('state_transition' => 1)
        begin
          yield failover_state
          @zk.set(@state_znode, Amplify::Failover::STATE_COMPLETE)
          @graphite.send_metrics('state_complete' => 1)
          @logger.info 'Now in active mode.'
        rescue => e
          @zk.set(@state_znode, Amplify::Failover::STATE_ERROR)
          @graphite.send_metrics('state_error' => 1)
          @logger.error "Failover failed: #{e.inspect}"
          @logger.error e.backtrace.join("\n")
        end
      end

      def set_client_data
        client_data = JSON.generate(@client_data || {})
        @zk.create(@client_data_znode, client_data, or: :set, mode: :persistent)
      end

      def mysql_poll_for_tracker(meta)
        total_time = 0
        start_time = Time.now

        # loop until the timeout is hit or the token is found
        loop do
          found = mysql_tracking_token_found?(meta)
          unless found
            sleep @tracking_poll_interval_secs
            total_time = Time.now - start_time
          end
          break unless total_time < @tracking_max_wait_secs && !found
        end

        if total_time > @tracking_max_wait_secs
          @logger.info 'Tracking token wait has expired.'
        else
          @logger.info 'Found tracking token.'
        end
      end

      def mysql_tracking_token_found?(meta)
        @db[:tracking]
          .where(version: meta.version)
          .where('mtime >= ?', meta.mtime).count > 0
      rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
        @logger.error e
        false
      end

      def mysql_insert_tracker(meta)
        @db[:tracking].insert(created_at: Time.now,
                              version: meta.version,
                              mtime: meta.mtime)
      rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
        @logger.error e
        false
      end

      # kill off any connections except for self and slave processes
    # TODO: make this more graceful.
      def mysql_kill_connections
        @logger.info 'Killing off database connections'
        mysql_with_slave_stopped do
          connections = @db[:information_schema__processlist].select(:id)
                          .where('id != CONNECTION_ID()')
                          .exclude(User: 'system user').all

          connections.each do |row|
            @logger.debug "Killing connection #{row[:id]}"
            begin
              @db["KILL #{row[:id]}"].update
            rescue => e
              @logger.warn e.inspect
            end
          end
        end
      rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
        @logger.error e
        false
      end

    # run some code with the MySQL slave threads stopped
    # This is primarily to avoid ungracefully killing the slave
    # threads in mysql_kill_connections
      def mysql_with_slave_stopped
        slave_status = @db['SHOW SLAVE STATUS'].first
        @logger.info 'Stopping slave threads if necessary.'
        @db['STOP SLAVE IO_THREAD'].update   if slave_status[:Slave_IO_Running]  == 'Yes'
        @db['STOP SLAVE SQL_THREAD'].update  if slave_status[:Slave_SQL_Running] == 'Yes'
        yield
        @logger.info 'Returning slave threads back to their previous state.'
        @db['START SLAVE SQL_THREAD'].update if slave_status[:Slave_SQL_Running] == 'Yes'
        @db['START SLAVE IO_THREAD'].update  if slave_status[:Slave_IO_Running]  == 'Yes'
      rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
        @logger.error e
        false
      end

      def mysql_read_only(read_only = true)
        @db['SET GLOBAL read_only = ?', read_only ? 1 : 0].update
      rescue Sequel::DatabaseError, Sequel::DatabaseConnectionError => e
        @logger.error e
        false
      end

    # Public: Register ephemeral znode for this host
    #
    # Examples
    #
    #   register_self_with_zk
    #
      def register_self_with_zk
        super
        @zk.create('/masters', ignore: :node_exists)
        @zk.create('/masters/node-', @watcher_server_id, mode: :ephemeral_sequential)
      end

      # presently active or passive?
      def active_master?
        @logger.debug "@active_master_id = #{@active_master_id.inspect}"
        @watcher_server_id == @active_master_id
      end

      def watch_active_master_id_znode
        # set the watch
        begin
          zk_node = @zk.get(@active_master_id_znode, watch: true)
          result = { value: zk_node.first, meta: zk_node.last }
        rescue ZK::Exceptions::NoNode
          @logger.error "No ZNode exists at #{@active_master_id_znode}. " \
                        "Create this znode with the server ID of the presently active master."
          @zk.stat(@active_master_id_znode, watch: true)
          result = nil
        end

        result
      end

      def register_callbacks
        @zk_watch = @zk.register(@active_master_id_znode) do |event|
          znode = watch_active_master_id_znode
          if event.node_deleted?
            @logger.info "#{@active_master_id_znode} has been deleted."
            @active_master_id = nil
          elsif event.node_changed? || event.node_created?
            @logger.info "#{@active_master_id_znode} changed.  New value: #{znode[:value]}"
            @queue.push(type: :active_master_changed,
                        value: znode[:value],
                        meta: znode[:meta])
          end
        end
      end

    # Public: set watches and get initial values for watched znodes
      def watch
        znode = watch_active_master_id_znode
        @logger.debug "in #watch: znode: #{znode.inspect}"
        if znode.is_a?(Hash)
          @active_master_id = znode[:value].empty? ? nil : normalize_server_id(znode[:value])
        else
          @active_master_id = nil
        end
      end

      def normalize_server_id(value)
        return nil if value.nil?
        value.is_a?(String) ? value : value.to_s
      end

      def status
        super && mysql_connected?
      end

      def status_hash
        super.merge(mysql_connected: mysql_connected?)
      end
    end
  end
end
