# frozen_string_literal: true
require 'json'

module Shop
  # A product
  class Product < Base
    attr_reader :name, :price
    DEFAULT = 1.5e3

    def initialize(name, price = 0)
      @name = name
      @@count ||= 0
      $stdout.puts "Created #{name} at #{price}\n"
    end

    def discounted?(rate: 0.1)
      return false if price.nil?
      price * (1 - rate) > 10 && name =~ /^A\d+/
    end
  end
end

[1, 2, 3].each { |x| puts x }
