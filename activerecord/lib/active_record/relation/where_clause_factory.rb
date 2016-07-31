module ActiveRecord
  class Relation
    class WhereClauseFactory # :nodoc:
      def initialize(klass, predicate_builder)
        @klass = klass
        @predicate_builder = predicate_builder # PredicateBuilder
      end

      def build(opts, other)
        case opts
        when String, Array # only parts
          parts_with_binds = [klass.send(:sanitize_sql, other.empty? ? opts : ([opts] + other))].flat_map do |part|
            WhereClause::PredicateWithBinds.new(part, [])
          end
        when Hash # parts and binds
          attributes = predicate_builder.resolve_column_aliases(opts)
          attributes = klass.send(:expand_hash_conditions_for_aggregates, attributes)
          attributes.stringify_keys!

          parts_with_binds = predicate_builder.build_predicate_binds_collection_from_hash(attributes)
        when Arel::Nodes::Node # parts and binds
          parts_with_binds = [WhereClause::PredicateWithBinds.new(opts, other)]
        else
          raise ArgumentError, "Unsupported argument type: #{opts} (#{opts.class})"
        end

        # WhereClause.new(predicates, binds)
        WhereClause.new(parts_with_binds)
      end

      protected

      attr_reader :klass, :predicate_builder
    end
  end
end
