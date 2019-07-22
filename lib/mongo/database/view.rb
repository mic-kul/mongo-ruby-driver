# Copyright (C) 2014-2019 MongoDB, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Mongo
  class Database

    # A class representing a view of a database.
    #
    # @since 2.0.0
    class View
      extend Forwardable
      include Enumerable
      include Retryable

      def_delegators :@database, :cluster, :read_preference, :client
      # @api private
      def_delegators :@database, :server_selector, :read_concern
      def_delegators :cluster, :next_primary

      # @return [ Integer ] batch_size The size of the batch of results
      #   when sending the listCollections command.
      attr_reader :batch_size

      # @return [ Integer ] limit The limit when sending a command.
      attr_reader :limit

      # @return [ Collection ] collection The command collection.
      attr_reader :collection

      # Get all the names of the non-system collections in the database.
      #
      # @example Get the collection names.
      #   database.collection_names
      #
      # @param [ Hash ] options Options for the listCollections command.
      #
      # @option options [ Integer ] :batch_size  The batch size for results
      #   returned from the listCollections command.
      #
      # @return [ Array<String> ] The names of all non-system collections.
      #
      # @since 2.0.0
      def collection_names(options = {})
        @batch_size = options[:batch_size]
        session = client.send(:get_session, options)
        cursor = read_with_retry_cursor(session, ServerSelector.primary, self) do |server|
          send_initial_query(server, session, name_only: true)
        end
        cursor.map do |info|
          if cursor.server.features.list_collections_enabled?
            info[Database::NAME]
          else
            (info[Database::NAME] &&
              info[Database::NAME].sub("#{@database.name}.", ''))
          end
        end
      end

      # Get info on all the collections in the database.
      #
      # @example Get info on each collection.
      #   database.list_collections
      #
      # @return [ Array<Hash> ] Info for each collection in the database.
      #
      # @since 2.0.5
      def list_collections
        session = client.send(:get_session)
        collections_info(session, ServerSelector.primary)
      end

      # Create the new database view.
      #
      # @example Create the new database view.
      #   View::Index.new(database)
      #
      # @param [ Database ] database The database.
      #
      # @since 2.0.0
      def initialize(database)
        @database = database
        @batch_size =  nil
        @limit = nil
        @collection = @database[Database::COMMAND]
      end

      # @api private
      attr_reader :database

      # Execute an aggregation on the database view.
      #
      # @example Aggregate documents.
      #   view.aggregate([
      #     { "$listLocalSessions" => {} }
      #   ])
      #
      # @param [ Array<Hash> ] pipeline The aggregation pipeline.
      # @param [ Hash ] options The aggregation options.
      #
      # @return [ Aggregation ] The aggregation object.
      #
      # @since 2.10.0
      # @api private
      def aggregate(pipeline, options = {})
        Collection::View::Aggregation.new(self, pipeline, options)
      end

      private

      def collections_info(session, server_selector, options = {}, &block)
        cursor = read_with_retry_cursor(session, server_selector, self) do |server|
          send_initial_query(server, session, options)
        end
        if block_given?
          cursor.each do |doc|
            yield doc
          end
        else
          cursor.to_enum
        end
      end

      def collections_info_spec(session, options = {})
        { selector: {
            listCollections: 1,
            cursor: batch_size ? { batchSize: batch_size } : {} },
          db_name: @database.name,
          session: session
        }.tap { |spec| spec[:selector][:nameOnly] = true if options[:name_only] }
      end

      def initial_query_op(session, options = {})
        Operation::CollectionsInfo.new(collections_info_spec(session, options))
      end

      def send_initial_query(server, session, options = {})
        initial_query_op(session, options).execute(server)
      end
    end
  end
end
