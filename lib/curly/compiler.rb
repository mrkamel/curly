require 'curly/scanner'
require 'curly/error'
require 'curly/invalid_reference'
require 'curly/invalid_block_error'
require 'curly/incorrect_ending_error'
require 'curly/incomplete_block_error'

module Curly

  # Compiles Curly templates into executable Ruby code.
  #
  # A template must be accompanied by a presenter class. This class defines the
  # references that are valid within the template.
  #
  class Compiler
    # Compiles a Curly template to Ruby code.
    #
    # template        - The template String that should be compiled.
    # presenter_class - The presenter Class.
    #
    # Returns a String containing the Ruby code.
    def self.compile(template, presenter_class)
      new(template, presenter_class).compile
    end

    # Whether the Curly template is valid. This includes whether all
    # references are available on the presenter class.
    #
    # template        - The template String that should be validated.
    # presenter_class - The presenter Class.
    #
    # Returns true if the template is valid, false otherwise.
    def self.valid?(template, presenter_class)
      compile(template, presenter_class)

      true
    rescue Error
      false
    end

    attr_reader :template, :presenter_class

    def initialize(template, presenter_class)
      @template, @presenter_class = template, presenter_class
    end

    def compile
      if presenter_class.nil?
        raise ArgumentError, "presenter class cannot be nil"
      end

      tokens = Scanner.scan(template)

      @blocks = []

      parts = tokens.map do |type, value|
        send("compile_#{type}", value)
      end

      if @blocks.any?
        raise IncompleteBlockError.new(@blocks.pop)
      end

      <<-RUBY
        buffer = ActiveSupport::SafeBuffer.new
        #{parts.join("\n")}
        buffer
      RUBY
    end

    private

    def compile_block_start(reference)
      compile_conditional_block "if", reference
    end

    def compile_inverse_block_start(reference)
      compile_conditional_block "unless", reference
    end

    def compile_conditional_block(keyword, reference)
      m = reference.match(/\A(.+?)(?:\.(.+))?\?\z/)
      method, argument = "#{m[1]}?", m[2]

      @blocks.push reference

      unless presenter_class.method_available?(method.to_sym)
        raise Curly::InvalidReference.new(method.to_sym)
      end

      if presenter_class.instance_method(method).arity == 1
        <<-RUBY
          #{keyword} presenter.#{method}(#{argument.inspect})
        RUBY
      else
        <<-RUBY
          #{keyword} presenter.#{method}
        RUBY
      end
    end

    def compile_block_end(reference)
      last_block = @blocks.pop

      unless last_block == reference
        raise Curly::IncorrectEndingError.new(reference, last_block)
      end

      <<-RUBY
        end
      RUBY
    end

    def compile_reference(reference)
      method, argument = reference.split(".", 2)

      unless presenter_class.method_available?(method.to_sym)
        raise Curly::InvalidReference.new(method.to_sym)
      end

      if presenter_class.instance_method(method).arity == 1
        # The method accepts a single argument -- pass it in.
        code = <<-RUBY
          presenter.#{method}(#{argument.inspect}) {|*args| yield(*args) }
        RUBY
      else
        code = <<-RUBY
          presenter.#{method} {|*args| yield(*args) }
        RUBY
      end

      'buffer.concat(%s.to_s)' % code.strip
    end

    def compile_text(text)
      'buffer.safe_concat(%s)' % text.inspect
    end

    def compile_comment(comment)
      "" # Replace the content with an empty string.
    end
  end
end
