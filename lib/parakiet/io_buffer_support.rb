# frozen_string_literal: true

module Parakiet
  # IO::Buffer lets the decompressors copy bytes around without allocating a String per copy.
  # It still carries an "experimental" warning, which is silenced once here: the gem only uses
  # new/for/copy/get_string/free, and falls back to String operations where it is missing.
  module IOBufferSupport
    AVAILABLE = begin
      if defined?(IO::Buffer) && IO::Buffer.method_defined?(:copy) && IO::Buffer.method_defined?(:get_string)
        previous = Warning[:experimental]
        begin
          Warning[:experimental] = false
          IO::Buffer.new(1).free
        ensure
          Warning[:experimental] = previous
        end
        ENV["PARAKIET_NO_IO_BUFFER"].nil?
      else
        false
      end
    rescue StandardError
      false
    end
  end
end
