# Compatibility shim: Ruby >= 3.2 / 4.x removed the legacy ERB.new signature
# ERB.new(str, safe_level, trim_mode, eoutvar). OpenHarmony's code generators
# still call that form. Map it onto the modern keyword form.
require 'erb'
if ERB.instance_method(:initialize).arity != 1
  module ERBCompat
    def initialize(str, safe_level = nil, trim_mode = nil, eoutvar = '_erbout', **kw)
      if safe_level.is_a?(String) && trim_mode.nil?
        trim_mode = safe_level
      elsif safe_level.is_a?(Hash)
        kw = safe_level
      elsif !safe_level.nil? && !trim_mode.nil?
        # legacy (str, safe_level, trim_mode): safe_level is ignored
      end
      super(str, trim_mode: trim_mode, eoutvar: eoutvar, **kw)
    end
  end
  ERB.prepend(ERBCompat)
end
