## LLVM IR

@target ptx foo() = return nothing
ir = sprint(io->code_llvm(io, foo, (),
                          #=strip_ir_metadata=#true, #=dump_module=#true))

# module should contain our function + a generic call wrapper
@test contains(ir, "define void @julia_foo")
@test contains(ir, "define %jl_value_t* @jlcall_foo")
@test ismatch(r"define void @julia_foo_.+\(\) #0.+\{", ir)
@test ismatch(r"define %jl_value_t\* @jlcall_", ir)
# module should be created for the PTX back-end
@test contains(ir, "!\"Julia Codegen Target\", !\"ptx\"")
# function should be generated by the PTX back-end
@test ismatch(r"attributes #0 = \{.+\"jl_cgtarget\"=\"ptx\".+\}", ir)
# code shouldn't contain a TLS pointer (NVPTX doesn't support TLS)
@test !contains(ir, "thread_ptr")


## PTX assembly

# TODO: PTX assembly generation / code_native
# -> test if foo and bar doesn't end up in same PTX module

# TODO: assert .entry
# TODO: assert devfun non .entry


@target ptx function throw_exception()
    throw(DivideError())
end
ir = sprint(io->code_llvm(io, throw_exception, ()))

# exceptions should get lowered to a plain trap...
@test contains(ir, "llvm.trap")
# not a jl_throw referencing a jl_value_t representing the exception
@test !contains(ir, "jl_value_t")
@test !contains(ir, "jl_throw")

# delayed binding lookup (due to noexisting global)
@target ptx ref_nonexisting() = nonexisting
@test_throws ErrorException code_native(DevNull, ref_nonexisting, ())

# generic call to nonexisting function
@target ptx call_nonexisting() = nonexisting()
@test_throws ErrorException code_native(DevNull, call_nonexisting, ())

# cannot call PTX functions
@target ptx call_nonptx() = return nothing
@test_throws MethodError call_nonptx()

# bug: generate code twice for the same kernel (jl_to_ptx wasn't idempotent)
@target ptx codegen_twice() = return nothing
code_native(DevNull, codegen_twice, ())
code_native(DevNull, codegen_twice, ())

# bug: depending on a child function from multiple parents resulted in
#      the child only being present once
let
    @target ptx @noinline function child(i)
        if i < 10
            return i*i
        else
            return (i-1)*(i+1)
        end
    end

    @target ptx function parent1(arr::Ptr{Int64})
        i = child(0)
        unsafe_store!(arr, i, i)
        return nothing
    end
    asm = sprint(io->code_native(io, parent1, (Ptr{Int64},)))
    @test ismatch(r".func .+ julia_child", asm)

    @target ptx function parent2(arr::Ptr{Int64})
        i = child(0)+1
        unsafe_store!(arr, i, i)

        return nothing
    end
    asm = sprint(io->code_native(io, parent2, (Ptr{Int64},)))
    @test ismatch(r".func .+ julia_child", asm)
end

# bug: similar, but slightly different issue as above
#      in the case of two child functions
let
    @target ptx @noinline function child1()
        return 0
    end

    @target ptx @noinline function child2()
        return 0
    end

    @target ptx function parent1(arry::Ptr{Int64})
        i = child1() + child2()
        unsafe_store!(arry, i, i)

        return nothing
    end
    asm = sprint(io->code_native(io, parent1, (Ptr{Int64},)))


    @target ptx function parent2(arry::Ptr{Int64})
        i = child1() + child2()
        unsafe_store!(arry, i, i+1)

        return nothing
    end
    asm = sprint(io->code_native(io, parent2, (Ptr{Int64},)))
end


# bug: use a system image function
let
    @target ptx @noinline function call_sysimg(a,i)
        Base.pointerset(a, 0, mod1(i,10), 8)
        return nothing
    end

    ir = sprint(io->code_llvm(io, call_sysimg, (Ptr{Int},Int)))
    @test !contains(ir, "jlsys_")
end
