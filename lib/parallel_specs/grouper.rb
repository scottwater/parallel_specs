# frozen_string_literal: true

module ParallelSpecs
  class Grouper
    class << self
      def in_even_groups_by_size(items, num_groups, options = {})
        groups = Array.new(num_groups) { {items: [], size: 0} }
        single_process_patterns = options[:single_process] || []
        single_items, items = items.partition do |item, _size|
          single_process_patterns.any? { |pattern| item.match?(pattern) }
        end
        isolate_count = isolated_process_count(options)

        if options.key?(:isolate_count) && !isolate_count.positive?
          raise ParallelSpecs::ConfigurationError, "Isolated process count must be greater than 0"
        end
        if isolate_count >= num_groups
          raise ParallelSpecs::ConfigurationError, "Isolated process count must be less than total process count"
        end

        if isolate_count.positive?
          group_by_size(single_items, groups.first(isolate_count))
          group_by_size(items, groups.drop(isolate_count))
        else
          single_items.each { |item, size| add_to_group(groups.first, item, size) }
          group_by_size(items, groups)
        end

        groups.map { |group| group[:items].sort }
      end

      private

      def isolated_process_count(options)
        options[:isolate_count] || (options[:isolate] ? 1 : 0)
      end

      def group_by_size(items, groups)
        items_to_group(items).each do |item, size|
          add_to_group(groups.min_by { |group| group[:size] }, item, size)
        end
      end

      def add_to_group(group, item, size)
        group[:items] << item
        group[:size] += size || 1
      end

      def items_to_group(items)
        return items unless items.first&.size == 2

        sizes = items.map { |(_item, size)| size || 1 }
        return items if sizes.uniq.one?

        items.sort_by { |(_item, size)| -(size || 1) }
      end
    end
  end
end
