require 'mirah/jvm/types'

class Java::JavaMethod
  def static?
    java.lang.reflect.Modifier.static?(modifiers)
  end

  def abstract?
    java.lang.reflect.Modifier.abstract?(modifiers)
  end
end

module Mirah::JVM::Types
  AST ||= Mirah::AST

  module ArgumentConversion
    def convert_args(compiler, values, types=nil)
      # TODO boxing/unboxing
      # TODO varargs
      types ||= argument_types
      values.zip(types).each do |value, type|
        compiler.compile(value, true)
        if type.primitive? && type != value.inferred_type
            value.inferred_type.widen(compiler.method, type)
        end
      end
    end
  end

  Type.send :include, ArgumentConversion

  class Intrinsic
    include ArgumentConversion
    attr_reader :name, :argument_types, :return_type

    def initialize(klass, name, args, type, &block)
      raise ArgumentError, "Block required" unless block_given?
      @class = klass
      @name = name
      @argument_types = args
      @return_type = type
      @block = block
    end

    def call(builder, ast, expression)
      @block.call(builder, ast, expression)
    end

    def declaring_class
      @class
    end

    def constructor?
      false
    end

    def field?
      false
    end

    def abstract?
      false
    end

    def exceptions
      []
    end
  end

  class JavaCallable
    include ArgumentConversion

    attr_accessor :member

    def initialize(member)
      @member = member
    end

    def name
      @name ||= @member.name
    end

    def field?
      false
    end

    def parameter_types
      @member.parameter_types
    end
  end

  class JavaConstructor < JavaCallable
    def argument_types
      @argument_types ||= @member.argument_types.map do |arg|
        if arg.kind_of?(AST::TypeReference) || arg.nil?
          arg
        else
          AST.type(nil, arg)
        end
      end
    end

    def return_type
      declaring_class
    end

    def exceptions
      @member.exception_types.map do |exception|
        if exception.kind_of?(Mirah::JVM::Types::Type)
          exception
        else
          Mirah::AST.type(nil, exception.class_name)
        end
      end
    end

    def declaring_class
      AST.type(nil, @member.declaring_class)
    end

    def call(compiler, ast, expression)
      target = ast.target.inferred_type
      compiler.method.new target
      compiler.method.dup if expression
      convert_args(compiler, ast.parameters)
      compiler.method.invokespecial(
        target,
        "<init>",
        [nil, *@member.argument_types])
    end

    def constructor?
      true
    end
  end

  class JavaMethod < JavaConstructor
    def return_type
      @return_type ||= begin
        if void?
          Void
        else
          AST.type(nil, @member.return_type)
        end
      end
    end

    def static?
      @member.static?
    end

    def abstract?
      @member.abstract?
    end

    def void?
      return_type = @member.return_type
      return true if return_type.nil?
      if return_type.respond_to?(:descriptor) && return_type.descriptor == 'V'
        return true
      end
      false
    end

    def constructor?
      false
    end

    def call(compiler, ast, expression)
      target = ast.target.inferred_type
      ast.target.compile(compiler, true)

      # if expression, void methods return the called object,
      # for consistency and chaining
      # TODO: inference phase needs to track that signature is
      # void but actual type is callee
      if expression && void?
        compiler.method.dup
      end

      convert_args(compiler, ast.parameters)
      if target.interface?
        compiler.method.invokeinterface(
          target,
          name,
          [@member.return_type, *@member.argument_types])
      else
        compiler.method.invokevirtual(
          target,
          name,
          [@member.return_type, *@member.argument_types])
      end

      unless expression || void?
        if return_type.wide?
          compiler.method.pop2
        else
          compiler.method.pop
        end
      end
    end

    def call_special(compiler, ast, expression)
      target = ast.target.inferred_type
      ast.target.compile(compiler, true)

      # if expression, void methods return the called object,
      # for consistency and chaining
      # TODO: inference phase needs to track that signature is
      # void but actual type is callee
      if expression && void?
        compiler.method.dup
      end

      convert_args(compiler, ast.parameters)
      if target.interface?
        raise "interfaces should not receive call_special"
      else
        compiler.method.invokespecial(
          target,
          name,
          [@member.return_type, *@member.argument_types])
      end

      unless expression || void?
        compiler.method.pop
      end
    end
  end

  class JavaStaticMethod < JavaMethod
    def call(compiler, ast, expression)
      target = declaring_class
      convert_args(compiler, ast.parameters)
      compiler.method.invokestatic(
        target,
        name,
        [@member.return_type, *@member.argument_types])
      # if expression, void static methods return null, for consistency
      # TODO: inference phase needs to track that signature is void
      # but actual type is null object
      compiler.method.aconst_null if expression && void?
      compiler.method.pop unless expression || void?
    end
  end

  class JavaDynamicMethod < JavaMethod
    def initialize(name, *types)
      @name = name
      @types = types
    end

    def return_type
      AST.type(nil, 'dynamic')
    end

    def declaring_class
      java.lang.Object
    end

    def argument_types
      @types
    end

    def call(compiler, ast, expression)
      target = ast.target.inferred_type
      ast.target.compile(compiler, true)

      ast.parameters.each do |param|
        param.compile(compiler, true)
      end
      compiler.method.invokedynamic(
        target,
        "dyn:callPropWithThis:#{name}",
        [return_type, target, *@types])

      unless expression
        compiler.method.pop
      end

      compiler.bootstrap_dynamic
    end
  end

  class JavaFieldAccessor < JavaMethod
    def field?
      true
    end

    def return_type
      AST.type(nil, @member.type)
    end

    def public?
      @member.public?
    end

    def final?
      @member.final?
    end
  end

  class JavaFieldGetter < JavaFieldAccessor
    def argument_types
      []
    end

    def call(compiler, ast, expression)
      target = ast.target.inferred_type

      # TODO: assert that no args are being passed, though that should have failed lookup

      if expression
        if @member.static?
          compiler.method.getstatic(target, name, @member.type)
        else
          ast.target.compile(compiler, true)
          compiler.method.getfield(target, name, @member.type)
        end
      end
    end
  end

  class JavaFieldSetter < JavaFieldAccessor
    def return_type
      AST.type(nil, @member.type)
    end

    def argument_types
      [AST.type(nil, @member.type)]
    end

    def call(compiler, ast, expression)
      target = ast.target.inferred_type

      # TODO: assert that no args are being passed, though that should have failed lookup

      if @member.static?
        convert_args(compiler, ast.parameters)
        compiler.method.dup if expression
        compiler.method.putstatic(target, name, @member.type)
      else
        ast.target.compile(compiler, true)
        convert_args(compiler, ast.parameters)
        compiler.method.dup_x2 if expression
        compiler.method.putfield(target, name, @member.type)
      end
    end
  end

  class MirahMember
    attr_reader :name, :argument_types, :declaring_class, :return_type
    attr_reader :exception_types

    def initialize(klass, name, args, return_type, static, exceptions)
      if return_type == Void
        return_type = nil
      end
      @declaring_class = klass
      @name = name
      @argument_types = args
      @return_type = return_type
      @static = static
      @exception_types = exceptions || []
    end

    def static?
      @static
    end

    def abstract?
      @declaring_class.interface?
    end
  end

  class Type
    def get_method(name, args)
      method = find_method(self, name, args, meta?)
      unless method
        # Allow constant narrowing for assignment methods
        if name =~ /=$/ && args[-1].respond_to?(:narrow!)
          if args[-1].narrow!
            method = find_method(self, name, args, meta?)
          end
        end
      end
      method
    end

    def constructor(*types)
      begin
        descriptors = types.map {|type| BiteScript::Signature.class_id(type)}
        constructor = jvm_type.getConstructor(*descriptors)
        return JavaConstructor.new(constructor) if constructor
      rescue => ex
        log(ex.message)
      end
      raise NameError, "No constructor #{name}(#{types.join ', '})"
    end

    def java_method(name, *types)
      intrinsic = intrinsics[name][types]
      return intrinsic if intrinsic
      jvm_types = types.map {|type| type.jvm_type}

      return JavaDynamicMethod.new(name, *jvm_types) if dynamic?

      begin
        descriptors = types.map {|type| BiteScript::Signature.class_id(type)}
        method = jvm_type.getDeclaredMethod(name, *descriptors)

        if method.nil? && superclass
          method = superclass.java_method(name, *types) rescue nil
        end

        if method.nil? && jvm_type.abstract?
          interfaces.each do |interface|
            method = interface.java_method(name, *types) rescue nil
            break if method
          end
        end

        return method if method.kind_of?(JavaCallable)
        if method && method.static? == meta?
          return JavaStaticMethod.new(method) if method.static?
          return JavaMethod.new(method)
        end
      rescue   => ex
        log(ex.message)
      end
      raise NameError, "No method #{self.name}.#{name}(#{types.join ', '})"
    end

    def declared_instance_methods(name=nil)
      methods = []
      if jvm_type && !array?
        jvm_type.getDeclaredMethods(name).each do |method|
          methods << JavaMethod.new(method) unless method.static?
        end
      end
      methods.concat((meta? ? unmeta : self).declared_intrinsics(name))
    end

    def declared_class_methods(name=nil)
      methods = []
      if jvm_type && !unmeta.array?
        jvm_type.getDeclaredMethods(name).each do |method|
          methods << JavaStaticMethod.new(method) if method.static?
        end
      end
      methods.concat(meta.declared_intrinsics(name))
    end

    def declared_constructors
      jvm_type.getConstructors.map do |method|
        JavaConstructor.new(method)
      end
    end

    def field_getter(name)
      if jvm_type
        field = jvm_type.getField(name)
        JavaFieldGetter.new(field) if field
      else
        nil
      end
    end

    def field_setter(name)
      if jvm_type
        field = jvm_type.getField(name)
        JavaFieldSetter.new(field) if field
      else
        nil
      end
    end

    def inner_class_getter(name)
      full_name = "#{self.name}$#{name}"
      inner_class = Mirah::AST.type(nil, full_name) rescue nil
      return unless inner_class
      inner_class.inner_class = true
      add_macro(name) do |transformer, call|
        Mirah::AST::Constant.new(call.parent, call.position, full_name)
      end
      intrinsics[name][[]]
    end
  end

  class TypeDefinition
    def java_method(name, *types)
      method = instance_methods[name].find {|m| m.argument_types == types}
      return method if method
      intrinsic = intrinsics[name][types]
      return intrinsic if intrinsic
      raise NameError, "No method #{self.name}.#{name}(#{types.join ', '})"
    end

    def java_static_method(name, *types)
      method = static_methods[name].find {|m| m.argument_types == types}
      return method if method
      intrinsic = meta.intrinsics[name][types]
      return intrinsic if intrinsic
      raise NameError, "No method #{self.name}.#{name}(#{types.join ', '})"
    end

    def constructor(*types)
      constructor = constructors.find {|c| c.argument_types == types}
      return constructor if constructor
      raise NameError, "No constructor #{name}(#{types.join ', '})"
    end

    def declared_instance_methods(name=nil)
      declared_intrinsics(name) + if name.nil?
        instance_methods.values.flatten
      else
        instance_methods[name]
      end
    end

    def declared_class_methods(name=nil)
      meta.declared_intrinsics(name) + if name.nil?
        static_methods.values.flatten
      else
        static_methods[name]
      end
    end

    def declared_constructors
      constructors
    end

    def constructors
      @constructors ||= []
    end

    def default_constructor
      if constructors.empty?
        declare_method('initialize', [], self, [])
        @default_constructor_added = true
        constructors[0]
      else
        constructor
      end
    end

    def instance_methods
      @instance_methods ||= Hash.new {|h, k| h[k] = []}
    end

    def static_methods
      @static_methods ||= Hash.new {|h, k| h[k] = []}
    end

    def declare_method(name, arguments, type, exceptions)
      raise "Bad args" unless arguments.all?
      member = MirahMember.new(self, name, arguments, type, false, exceptions)
      if name == 'initialize'
        if @default_constructor_added
          unless arguments.empty?
            raise "Can't add constructor #{member} after using the default."
          end
        else
          constructors << JavaConstructor.new(member)
        end
      else
        instance_methods[name] << JavaMethod.new(member)
      end
    end

    def declare_static_method(name, arguments, type, exceptions)
      member = MirahMember.new(self, name, arguments, type, true, exceptions)
      static_methods[name] << JavaStaticMethod.new(member)
    end

    def interface?
      false
    end

    def field_getter(name)
      nil
    end

    def field_setter(name)
      nil
    end
  end

  class TypeDefMeta
    def constructor(*args)
      unmeta.constructor(*args)
    end

    def java_method(*args)
      unmeta.java_static_method(*args)
    end

    def declared_class_methods(name=nil)
      unmeta.declared_class_methods(name)
    end

    def declared_instance_methods(name=nil)
      unmeta.declared_instance_methods(name)
    end

    def field_getter(name)
      nil
    end

    def field_setter(name)
      nil
    end
  end
end