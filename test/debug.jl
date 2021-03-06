using JuliaInterpreter, Test
using JuliaInterpreter: enter_call, enter_call_expr, get_return, @lookup
using Base.Meta: isexpr

const ALL_COMMANDS = (:n, :s, :c, :finish, :nc, :se, :si)

function step_through_command(fr::Frame, cmd::Symbol)
    while true
        ret = JuliaInterpreter.debug_command(JuliaInterpreter.finish_and_return!, fr, cmd)
        ret == nothing && break
        fr, pc = ret
    end
    @test fr.callee === nothing
    @test fr.caller === nothing
    return get_return(fr)
end

function step_through_frame(frame_creator)
    rets = []
    for cmd in ALL_COMMANDS
        frame = frame_creator() 
        ret = step_through_command(frame, cmd)
        push!(rets, ret)
    end
    @test all(ret -> ret == rets[1], rets)
    return rets[1]
end
step_through(f, args...; kwargs...) = step_through_frame(() -> enter_call(f, args...; kwargs...))
step_through(expr::Expr) = step_through_frame(() -> enter_call_expr(expr))

@generated function generatedfoo(T)
    :(return $T)
end
callgenerated() = generatedfoo(1)
@generated function generatedparams(a::Array{T,N}) where {T,N}
    :(return ($T,$N))
end
callgeneratedparams() = generatedparams([1 2; 3 4])

macro insert_some_calls()
    esc(quote
        x = sin(b)
        y = asin(x)
        z = sin(y)
    end)
end

trivial(x) = x

struct B{T} end

# @testset "Debug" begin
    @testset "Basics" begin
        frame = enter_call(map, x->2x, 1:10)
        @test debug_command(frame, :finish) === nothing
        @test frame.caller === frame.callee === nothing
        @test get_return(frame) == map(x->2x, 1:10)

        function complicated_keyword_stuff(args...; kw...)
            args[1] == args[1]
            (args..., kw...)
        end
        for (args, kwargs) in (((1,), ()), ((1, 2), (x=7, y=33)))
            frame = enter_call(complicated_keyword_stuff, args...; kwargs...)
            f, pc = debug_command(frame, :n)
            @test f === frame
            @test isa(pc, Int)
            @test debug_command(frame, :finish) === nothing
            @test frame.caller === frame.callee === nothing
            @test get_return(frame) == complicated_keyword_stuff(args...; kwargs...)
        end

        f22() = string(:(a+b))
        @test step_through(f22) == "a + b"
        f22() = string(QuoteNode(:a))
        @test step_through(f22) == ":a"

        frame = enter_call(trivial, 2)
        @test debug_command(frame, :s) === nothing
        @test get_return(frame) == 2

        @test step_through(trivial, 2) == 2
        @test step_through(:($(+)(1,2.5))) == 3.5
        @test step_through(:($(sin)(1))) == sin(1)
        @test step_through(:($(gcd)(10,20))) == gcd(10, 20)
    end

    @testset "generated" begin
        frame = enter_call_expr(:($(callgenerated)()))
        f, pc = debug_command(frame, :s)
        @test isa(pc, BreakpointRef)
        @test JuliaInterpreter.scopeof(f).name == :generatedfoo
        stmt = JuliaInterpreter.pc_expr(f)
        @test stmt.head == :return && stmt.args[1] === Int
        @test debug_command(frame, :c) === nothing
        @test frame.callee === nothing
        @test get_return(frame) === Int
        # This time, step into the generated function itself
        frame = enter_call_expr(:($(callgenerated)()))
        f, pc = debug_command(frame, :sg)
        @test isa(pc, BreakpointRef)
        @test JuliaInterpreter.scopeof(f).name == :generatedfoo
        stmt = JuliaInterpreter.pc_expr(f)
        @test stmt.head == :return && @lookup(f, stmt.args[1]) === 1
        f2, pc = debug_command(f, :finish)
        @test JuliaInterpreter.scopeof(f2).name == :callgenerated
        # Now finish the regular function
        @test debug_command(frame, :finish) === nothing
        @test frame.callee === nothing
        @test get_return(frame) === 1

        # Parametric generated function (see #157)
        frame = fr = JuliaInterpreter.enter_call(callgeneratedparams)
        while fr.pc < JuliaInterpreter.nstatements(fr.framecode) - 1
            fr, pc = debug_command(fr, :se)
        end
        fr, pc = debug_command(fr, :sg)
        @test JuliaInterpreter.scopeof(fr).name == :generatedparams
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test JuliaInterpreter.get_return(fr) == (Int, 2)
    end

    @testset "Optional arguments" begin
        function optional(n = sin(1))
            x = asin(n)
            cos(x)
        end
        frame = JuliaInterpreter.enter_call_expr(:($(optional)()))
        # First call steps in and executes the first statement
        f, pc = debug_command(frame, :n)
        @test frame !== f
        # cos(1.0)
        debug_command(f, :n)
        # return
        f2, pc = debug_command(f, :n)
        @test f2 === frame
        @test debug_command(frame, :n) === nothing
    end

    @testset "Keyword arguments" begin
        f(x; b = 1) = x+b
        g() = f(1; b = 2)
        frame = JuliaInterpreter.enter_call_expr(:($(g)()));
        fr, pc = debug_command(frame, :nc)
        fr, pc = debug_command(fr, :nc)
        fr, pc = debug_command(fr, :nc)
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test frame.callee === nothing
        @test get_return(frame) == 3

        frame = JuliaInterpreter.enter_call(f, 2; b = 4)
        fr = JuliaInterpreter.maybe_step_through_wrapper!(frame)
        fr, pc = debug_command(fr, :nc)
        fr, pc = debug_command(fr, :nc)
        @test get_return(frame) == 6
    end

    @testset "Optional + keyword wrappers" begin
        opkw(a, b=1; c=2, d=3) = 1
        callopkw1() = opkw(0)
        callopkw2() = opkw(0, -1)
        callopkw3() = opkw(0; c=-2)
        callopkw4() = opkw(0, -1; c=-2)
        callopkw5() = opkw(0; c=-2, d=-3)
        callopkw6() = opkw(0, -1; c=-2, d=-3)
        scopes = Method[]
        for f in (callopkw1, callopkw2, callopkw3, callopkw4, callopkw5, callopkw6)
            frame = fr = JuliaInterpreter.enter_call(f)
            pc = fr.pc
            while pc <= JuliaInterpreter.nstatements(fr.framecode) - 2
                fr, pc = debug_command(fr, :se)
            end
            fr, pc = debug_command(frame, :si)
            @test stacklength(frame) == 2
            frame = fr = JuliaInterpreter.enter_call(f)
            pc = fr.pc
            while pc <= JuliaInterpreter.nstatements(fr.framecode) - 2
                fr, pc = debug_command(fr, :se)
            end
            fr, pc = debug_command(frame, :s)
            @test stacklength(frame) > 2
            push!(scopes, JuliaInterpreter.scopeof(fr))
        end
        @test length(unique(scopes)) == 1  # all get to the body method
    end

    @testset "Macros" begin
        # Work around the fact that we can't detect macro expansions if the macro
        # is defined in the same file
        include_string(Main, """
        function test_macro()
            a = sin(5)
            b = asin(a)
            @insert_some_calls
            z
        end
        ""","file.jl")
        frame = JuliaInterpreter.enter_call_expr(:($(test_macro)()))
        f, pc = debug_command(frame, :n)        # a is set
        f, pc = debug_command(f, :n)            # b is set
        f, pc = debug_command(f, :n)            # x is set
        f, pc = debug_command(f, :n)            # y is set
        f, pc = debug_command(f, :n)            # z is set
        @test debug_command(f, :n) === nothing  # return
    end

    @testset "Quoting" begin
        # Test that symbols don't get an extra QuoteNode
        f_symbol() = :limit => true
        frame = JuliaInterpreter.enter_call(f_symbol)
        fr, pc = debug_command(frame, :s)
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test get_return(frame) == f_symbol()
    end

    @testset "Varargs" begin
        f_va_inner(x) = x + 1
        f_va_outer(args...) = f_va_inner(args...)
        frame = fr = JuliaInterpreter.enter_call(f_va_outer, 1)
        # depending on whether this is in or out of a @testset, the first statement may differ
        stmt1 = fr.framecode.src.code[1]
        if isexpr(stmt1, :call) && @lookup(frame, stmt1.args[1]) === getfield
            fr, pc = debug_command(fr, :se)
        end
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :n)
        @test root(fr) !== fr
        fr, pc = debug_command(fr, :finish)
        @test debug_command(fr, :finish) === nothing
        @test get_return(frame) === 2
    end

    @testset "ASTI#17" begin
        function (::B)(y)
            x = 42*y
            return x + y
        end
        B_inst = B{Int}()
        step_through(B_inst, 10) == B_inst(10)
    end

    @testset "Exceptions" begin
        # Don't break on caught exceptions
        err_caught = Any[nothing]
        function f_exc_outer()
            try
                f_exc_inner()
            catch err;
                err_caught[1] = err
            end
            x = 1 + 1
            return x
        end
        f_exc_inner() = error()
        fr = JuliaInterpreter.enter_call(f_exc_outer)
        fr, pc = debug_command(fr, :s)
        fr, pc = debug_command(fr, :n)
        fr, pc = debug_command(fr, :n)
        debug_command(fr, :finish)
        @test get_return(fr) == 2
        @test first(err_caught) isa ErrorException
        @test stacklength(fr) == 1

        err_caught = Any[nothing]
        fr = JuliaInterpreter.enter_call(f_exc_outer)
        fr, pc = debug_command(fr, :s)
        debug_command(fr, :c)
        @test get_return(root(fr)) == 2
        @test first(err_caught) isa ErrorException
        @test stacklength(root(fr)) == 1

        # Rethrow on uncaught exceptions
        f_outer() = g_inner()
        g_inner() = error()
        fr = JuliaInterpreter.enter_call(f_outer)
        @test_throws ErrorException debug_command(fr, :finish)
        @test stacklength(fr) == 1

        # Break on error
        try
            break_on(:error)
            fr = JuliaInterpreter.enter_call(f_outer)
            fr, pc = debug_command(JuliaInterpreter.finish_and_return!, fr, :finish)
            @test fr.framecode.scope.name == :error

            fundef() = undef_func()
            frame = JuliaInterpreter.enter_call(fundef)
            fr, pc = debug_command(frame, :s)
            @test isa(pc, BreakpointRef)
            @test pc.err isa UndefVarError
        finally
            break_off(:error)
        end

        @testset "breakpoints" begin
            # In source breakpoints
            function f_bp(x)
                #=1=#    i = 1
                #=2=#    @label foo
                #=3=#    @bp
                #=4=#    repr("foo")
                #=5=#    i += 1
                #=6=#    i > 3 && return x
                #=7=#    @goto foo
            end
            ln = @__LINE__
            method_start = ln - 9
            fr = enter_call(f_bp, 2)
            @test JuliaInterpreter.linenumber(fr) == method_start + 1
            fr, pc =  JuliaInterpreter.debug_command(fr, :c)
            # Hit the breakpoint x1
            @test JuliaInterpreter.linenumber(fr) == method_start + 3
            @test pc isa BreakpointRef
            fr, pc =  JuliaInterpreter.debug_command(fr, :n)
            @test JuliaInterpreter.linenumber(fr) == method_start + 4
            fr, pc =  JuliaInterpreter.debug_command(fr, :c)
            # Hit the breakpoint again x2
            @test pc isa BreakpointRef
            @test JuliaInterpreter.linenumber(fr) == method_start + 3
            fr, pc =  JuliaInterpreter.debug_command(fr, :c)
            # Hit the breakpoint for the last time x3
            @test pc isa BreakpointRef
            @test JuliaInterpreter.linenumber(fr) == method_start + 3
            JuliaInterpreter.debug_command(fr, :c)
            @test get_return(fr) == 2
        end
    end
# end
