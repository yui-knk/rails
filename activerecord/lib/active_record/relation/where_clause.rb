module ActiveRecord
  class Relation
    class WhereClause # :nodoc:
      class PredicateWithBinds < Struct.new(:predicate, :binds)
        def self.empty
          new(nil, [])
        end

        def empty?
          predicate.nil? && binds.empty?
        end
      end

      attr_reader :predicate_binds_collection

      delegate :any?, :empty?, to: :predicates

      # [PredicateWithBinds, PredicateWithBinds, ...]
      def initialize(predicate_binds_collection)
        @predicate_binds_collection = predicate_binds_collection
      end

      def binds
        predicate_binds_collection.reject(&:empty?).inject([]) do |results, predicate_binds|
          results + predicate_binds.binds
        end
      end

      def +(other)
        WhereClause.new(
          predicate_binds_collection.reject(&:empty?) + other.predicate_binds_collection
        )
      end

      def merge(other)
        WhereClause.new(
          predicate_binds_unreferenced_by(other) + other.predicate_binds_collection
        )
      end

      def except(*columns)
        WhereClause.new(
          predicate_binds_except(columns)
        )
      end

      def or(other)
        if empty?
          self
        elsif other.empty?
          other
        else
          WhereClause.new([PredicateWithBinds.new(ast.or(other.ast), binds + other.binds)])
        end
      end

      def to_h(table_name = nil)
        equalities = predicate_binds_collection.reject(&:empty?).select do |predicate_bind|
          predicate_bind.predicate.is_a? Arel::Nodes::Equality
        end

        if table_name
          equalities = equalities.select do |predicate_bind|
            predicate_bind.predicate.left.relation.name == table_name
          end
        end

        equalities.map { |predicate_bind|
          node = predicate_bind.predicate
          key = node.left.name
          value = predicate_bind.binds.first.try!(:value) || begin
            case node.right
            when Array then node.right.map(&:val)
            when Arel::Nodes::Casted, Arel::Nodes::Quoted
              node.right.val
            end
          end

          [key, value]
        }.to_h
      end

      def ast
        Arel::Nodes::And.new(predicates_with_wrapped_sql_literals)
      end

      def ==(other)
        other.is_a?(WhereClause) &&
          predicates == other.predicates &&
          binds == other.binds
      end

      def invert
        WhereClause.new(inverted_predicates)
      end

      def self.empty
        @empty ||= new([PredicateWithBinds.empty])
      end

      protected

      def predicates
        predicate_binds_collection.reject(&:empty?).inject([]) do |results, predicate_binds|
          results << predicate_binds.predicate
        end
      end

      def referenced_columns
        @referenced_columns ||= begin
          equality_nodes = predicates.select { |n| equality_node?(n) }
          Set.new(equality_nodes, &:left)
        end
      end

      private

      def predicate_binds_unreferenced_by(other)
        predicate_binds_collection.reject(&:empty?).reject do |predicate_bind|
          equality_node?(predicate_bind.predicate) && other.referenced_columns.include?(predicate_bind.predicate.left)
        end
      end

      def equality_node?(node)
        node.respond_to?(:operator) && node.operator == :==
      end

      def non_conflicting_binds(other)
        conflicts = referenced_columns & other.referenced_columns
        conflicts.map! { |node| node.name.to_s }
        binds.reject { |attr| conflicts.include?(attr.name) }
      end

      def inverted_predicates
        predicate_binds_collection.map do |predicate_bind|
          PredicateWithBinds.new(invert_predicate(predicate_bind.predicate), predicate_bind.binds)
        end
      end

      def invert_predicate(node)
        case node
        when NilClass
          raise ArgumentError, 'Invalid argument for .where.not(), got nil.'
        when Arel::Nodes::In
          Arel::Nodes::NotIn.new(node.left, node.right)
        when Arel::Nodes::Equality
          Arel::Nodes::NotEqual.new(node.left, node.right)
        when String
          Arel::Nodes::Not.new(Arel::Nodes::SqlLiteral.new(node))
        else
          Arel::Nodes::Not.new(node)
        end
      end

      def predicate_binds_except(columns)
        predicate_binds_collection.reject(&:empty?).reject do |predicate_bind|
          node = predicate_bind.predicate

          case node
          when Arel::Nodes::Between, Arel::Nodes::In, Arel::Nodes::NotIn, Arel::Nodes::Equality, Arel::Nodes::NotEqual, Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual, Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual
            subrelation = (node.left.kind_of?(Arel::Attributes::Attribute) ? node.left : node.right)
            columns.include?(subrelation.name.to_s)
          end
        end
      end

      def binds_except(columns)
        binds.reject do |attr|
          columns.include?(attr.name)
        end
      end

      def predicates_with_wrapped_sql_literals
        non_empty_predicates.map do |node|
          if Arel::Nodes::Equality === node
            node
          else
            wrap_sql_literal(node)
          end
        end
      end

      ARRAY_WITH_EMPTY_STRING = ['']
      def non_empty_predicates
        predicates - ARRAY_WITH_EMPTY_STRING
      end

      def wrap_sql_literal(node)
        if ::String === node
          node = Arel.sql(node)
        end
        Arel::Nodes::Grouping.new(node)
      end
    end
  end
end
