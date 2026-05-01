# frozen_string_literal: true

require 'json'

module ParallelSpecs
  class Pids
    def initialize(file_path)
      @file_path = file_path
      @mutex = Mutex.new
    end

    def add(pid)
      mutex.synchronize do
        read
        pids << pid.to_i
        save
      end
    end

    def delete(pid)
      mutex.synchronize do
        read
        pids.delete(pid.to_i)
        save
      end
    end

    def all
      mutex.synchronize do
        read
        pids.dup
      end
    end

    private

    attr_reader :file_path, :mutex

    def pids
      @pids ||= []
    end

    def read
      return unless File.exist?(file_path)

      contents = File.read(file_path)
      @pids = []
      return if contents.empty?

      @pids = JSON.parse(contents)
    end

    def save
      File.write(file_path, pids.to_json)
    end
  end
end
