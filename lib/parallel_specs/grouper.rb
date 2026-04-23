# frozen_string_literal: true

module ParallelSpecs
  class Grouper
    class << self
      def in_even_groups_by_size(items, num_groups, _options = {})
        groups = Array.new(num_groups) { { items: [], size: 0 } }

        items_to_group(items).each do |item, size|
          group = groups.min_by { |entry| entry[:size] }
          group[:items] << item
          group[:size] += (size || 1)
        end

        groups.map { |group| group[:items].sort }
      end

      private

      def items_to_group(items)
        return items unless items.first&.size == 2

        sizes = items.map { |(_item, size)| size || 1 }
        return items if sizes.uniq.one?

        items.sort_by { |(_item, size)| -(size || 1) }
      end
    end
  end
end
