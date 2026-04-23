# frozen_string_literal: true

require 'json'

module ParallelSpecs
  class Pids
    def initialize(file_path)
      @file_path = file_path
      @mutex = Mutex.new
    end

    def add(pid)
      pids << pid.to_i
      save
    end

    def delete(pid)
      pids.delete(pid.to_i)
      save
    end

    def count
      read
      pids.count
    end

    def all
      read
      pids
    end

    private

    attr_reader :file_path, :mutex

    def pids
      @pids ||= []
    end

    def read
      mutex.synchronize do
        return unless File.exist?(file_path)

        contents = File.read(file_path)
        return if contents.empty?

        @pids = JSON.parse(contents)
      end
    end

    def save
      mutex.synchronize { File.write(file_path, pids.to_json) }
    end
  end
end
