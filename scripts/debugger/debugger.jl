module VSCodeDebugger

include("../terminalserver/repl.jl")

# This patches JuliaInterpreter.jl to use our private copy of CodeTracking.jl
filename_of_juliainterpreter = joinpath(@__DIR__, "packages", "JuliaInterpreter", "src", "JuliaInterpreter.jl")
filename_of_codetracking = joinpath(@__DIR__, "packages", "CodeTracking", "src", "CodeTracking.jl")
filename_of_codetracking = replace(filename_of_codetracking, "\\"=>"\\\\")
jlinterp_code = read(filename_of_juliainterpreter, String)
jlinterp_code_patched = replace(jlinterp_code, "using CodeTracking"=>"include(\"$filename_of_codetracking\"); using .CodeTracking")
withpath(filename_of_juliainterpreter) do
    include_string(VSCodeDebugger, jlinterp_code_patched, filename_of_juliainterpreter)
end

import .JuliaInterpreter
import Sockets, Base64

function _parse_julia_file(filename::String)
    return Base.parse_input_line(read(filename, String); filename=filename)
end

function our_debug_command(frame, cmd, modexs, not_yet_set_function_breakpoints)
    ret = nothing
    while true
        @debug "Now running the following FRAME:"
        @debug frame

        ret = JuliaInterpreter.debug_command(frame, cmd, true)

        for func_name in not_yet_set_function_breakpoints
            @debug "setting func breakpoint for $func_name"
            try
                f = Main.eval(Meta.parse(func_name))
                @debug "Setting breakpoint for $f"
                JuliaInterpreter.breakpoint(f)
                delete!(not_yet_set_function_breakpoints, func_name)
            catch err
                push!(not_yet_set_function_breakpoints, func_name)
            end
        end        

        # @debug "We got $ret"

        if ret!==nothing || length(modexs)==0
            break
        end

        insert_bp!(modexs[1][2])
        frame = JuliaInterpreter.prepare_thunk(modexs[1])        
        deleteat!(modexs, 1)

        ret!==nothing && error("THIS SHOULDN't happen")

        if ret===nothing && (cmd==:n || JuliaInterpreter.shouldbreak(frame, frame.pc))
            ret = (frame, nothing)
            break
        end
    end

    return ret
end

function decode_msg(line::AbstractString)
    pos = findfirst(':', line)
    pos2 = findnext(':', line, pos+1)

    msg_id = line[1:pos-1]        
    msg_cmd = line[pos+1:pos2-1]
    msg_body_encoded = line[pos2+1:end]
    msg_body = String(Base64.base64decode(msg_body_encoded))
    return msg_id, msg_cmd, msg_body
end

function send_msg(conn, msg_cmd::AbstractString, msg_id::AbstractString, msg_body::AbstractString="")
    encoded_msg_body = Base64.base64encode(msg_body)
    println(conn, msg_cmd, ':', msg_id, ':', encoded_msg_body)
end

function lowercase_drive(a)
    if length(a) >= 2 && a[2]==':'
        return lowercase(a[1]) * a[2:end]
    else
        return a
    end
end

function insert_bp!(expr)
    i = length(expr.args)
    for arg in reverse(expr.args)
        if arg isa LineNumberNode
            lln = arg
            for bp in JuliaInterpreter.breakpoints()
                if bp isa JuliaInterpreter.BreakpointFileLocation
                    if lowercase_drive(string(lln.file)) == lowercase_drive(bp.abspath) && lln.line == bp.line                        
                        insert!(expr.args, i, JuliaInterpreter.BREAKPOINT_EXPR)
                        insert!(expr.args, i, lln)
                        i -= 1
                    end
                end
            end
        end
        if arg isa Expr && !(arg.head in (:function, :struct))
            insert_bp!(arg)
        end
        i -= 1
    end
end

function startdebug(pipename)
    conn = Sockets.connect(pipename)
    try
        modexs = []
        frame = nothing

        not_yet_set_function_breakpoints = Set{String}()

        sources = Dict{Int,String}()
        curr_source_id = 1

        while true      
            @debug "Current FRAME is"    
            @debug frame
            @debug "NOW WAITING FOR COMMAND FROM DAP"
            le = readline(conn)

            msg_id, msg_cmd, msg_body = decode_msg(le)
            
            @debug "COMMAND is '$msg_cmd'"

            if msg_cmd=="DISCONNECT"
                @debug "DISCONNECT"
                break
            elseif msg_cmd=="RUN"
                @debug "WE ARE RUNNING"
                try
                    include(msg_body)
                catch err
                    Base.display_error(stderr, err, catch_backtrace())
                end

                send_msg(conn, "FINISHED", "notification")                
            elseif msg_cmd=="DEBUG"
                index_of_sep = findfirst(';', msg_body)

                stop_on_entry_as_string = msg_body[1:index_of_sep-1]

                stop_on_entry = stop_on_entry_as_string=="stopOnEntry=true"

                filename_to_debug = msg_body[index_of_sep+1:end]

                @debug "We are debugging $filename_to_debug"

                ex = _parse_julia_file(filename_to_debug)

                @debug typeof(ex)
                @debug ex

                modexs, _ = JuliaInterpreter.split_expressions(Main, ex)

                insert_bp!(modexs[1][2])
                frame = JuliaInterpreter.prepare_thunk(modexs[1])
                deleteat!(modexs, 1)

                if stop_on_entry
                    send_msg(conn, "STOPPEDENTRY", "notification")
                elseif JuliaInterpreter.shouldbreak(frame, frame.pc)
                    send_msg(conn, "STOPPEDBP", "notification")
                else
                    ret = our_debug_command(frame, :finish, modexs, not_yet_set_function_breakpoints)

                    if ret===nothing
                        send_msg(conn, "FINISHED", "notification")
                    else
                        frame = ret[1]
                        send_msg(conn, "STOPPEDBP", "notification")
                    end
                end
            elseif msg_cmd=="EXEC"
                @debug "WE ARE EXECUTING"
    
                ex = Meta.parse(msg_body)

                modexs, _ = JuliaInterpreter.split_expressions(Main, ex)
    
                insert_bp!(modexs[1][2])
                frame = JuliaInterpreter.prepare_thunk(modexs[1])
                deleteat!(modexs, 1)
    
                ret = our_debug_command(frame, :finish, modexs, not_yet_set_function_breakpoints)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_msg(conn, "STOPPEDBP", "notification")
                end                
            elseif msg_cmd=="TERMINATE"
                send_msg(conn, "FINISHED", "notification")
            elseif msg_cmd=="SETBREAKPOINTS"
                splitted_line = split(msg_body, ';')

                lines_as_num = parse.(Int, splitted_line[2:end])
                file = splitted_line[1]

                for bp in JuliaInterpreter.breakpoints()
                    if bp isa JuliaInterpreter.BreakpointFileLocation
                        if bp.path==file
                            JuliaInterpreter.remove(bp)
                        end
                    end
                end
    
                for line_as_num in lines_as_num
                    @debug "Setting one breakpoint at line $line_as_num in file $file"
    
                    JuliaInterpreter.breakpoint(string(file), line_as_num)                        
                end
            elseif msg_cmd=="SETEXCEPTIONBREAKPOINTS"
                opts = Set(split(msg_body, ';'))

                if "error" in opts                    
                    JuliaInterpreter.break_on(:error)
                else
                    JuliaInterpreter.break_off(:error)
                end

                if "throw" in opts
                    JuliaInterpreter.break_on(:throw )
                else
                    JuliaInterpreter.break_off(:throw )
                end
            elseif msg_cmd=="SETFUNCBREAKPOINTS"
                @debug "SETTING FUNC BREAKPOINT"                

                func_names = split(msg_body, ';', keepempty=false)

                @debug func_names

                for bp in JuliaInterpreter.breakpoints()
                    if bp isa JuliaInterpreter.BreakpointSignature
                        JuliaInterpreter.remove(bp)
                    end
                end

                for func_name in func_names
                    @debug "setting func breakpoint for $func_name"
                    try
                        f = Main.eval(Meta.parse(func_name))
                        @debug "Setting breakpoint for $f"
                        JuliaInterpreter.breakpoint(f)
                    catch err
                        push!(not_yet_set_function_breakpoints, func_name)
                    end
                end
            elseif msg_cmd=="GETSTACKTRACE"
                @debug "Stacktrace requested"

                fr = frame

                curr_fr = JuliaInterpreter.leaf(fr)

                frames_as_string = String[]

                id = 1
                while curr_fr!==nothing
                    @debug "UUUUUU"

                    @debug JuliaInterpreter.scopeof(curr_fr)
                    @debug typeof(JuliaInterpreter.scopeof(curr_fr))
                    @debug JuliaInterpreter.whereis(curr_fr)
                    @debug typeof(JuliaInterpreter.whereis(curr_fr))

                    # This can be either a Method or a Module
                    curr_scopeof = JuliaInterpreter.scopeof(curr_fr)
                    curr_whereis = JuliaInterpreter.whereis(curr_fr)
                    # TODO This is a bug fix, for some reason curr_whereis[1]
                    # returns a truncated filename
                    fname = curr_whereis[1]

                    # @show fname
                    # @show typeof(curr_scopeof)
                    # @show curr_scopeof
                    # @show curr_whereis
                    if isfile(fname)
                        push!(frames_as_string, string(id, ";", curr_scopeof isa Method ? curr_scopeof.name : string(curr_scopeof), ";path;", fname, ";", curr_whereis[2]))
                    elseif curr_scopeof isa Method
                        sources[curr_source_id], loc = JuliaInterpreter.CodeTracking.definition(String, curr_fr.framecode.scope)
                        push!(frames_as_string, string(id, ";", curr_scopeof isa Method ? curr_scopeof.name : string(curr_scopeof), ";ref;", curr_source_id, ";", curr_whereis[2], ";", fname))
                        curr_source_id += 1
                    end
                    
                    id += 1
                    curr_fr = curr_fr.caller
                end

                send_msg(conn, "RESPONSE", msg_id, join(frames_as_string, '\n'))
                @debug "DONE SENDING stacktrace"
            elseif msg_cmd=="GETSOURCE"
                source_id = parse(Int, msg_body)

                send_msg(conn, "RESPONSE", msg_id, sources[source_id])
            elseif msg_cmd=="GETVARIABLES"
                @debug "START VARS"

                frameId = parse(Int, msg_body)

                fr = frame
                curr_fr = JuliaInterpreter.leaf(fr)

                i = 1

                while frameId > i
                    curr_fr = curr_fr.caller
                    i += 1
                end

                vars = JuliaInterpreter.locals(curr_fr)

                vars_as_string = String[]

                for v in vars
                    # TODO Figure out why #self# is here in the first place
                    # For now we don't report it to the client
                    if !startswith(string(v.name), "#")
                        push!(vars_as_string, string(v.name, ";", typeof(v.value), ";", v.value))
                    end
                end

                if JuliaInterpreter.isexpr(JuliaInterpreter.pc_expr(curr_fr), :return)
                    ret_val = JuliaInterpreter.get_return(curr_fr)
                    push!(vars_as_string, string("Return Value", ";", typeof(ret_val), ";", ret_val))
                end

                send_msg(conn, "RESPONSE", msg_id, join(vars_as_string, '\n'))
                @debug "DONE VARS"
            elseif msg_cmd=="CONTINUE"
                ret = our_debug_command(frame, :c, modexs, not_yet_set_function_breakpoints)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_msg(conn, "STOPPEDBP", "notification")
                end
            elseif msg_cmd=="NEXT"
                @debug "NEXT COMMAND"
                ret = our_debug_command(frame, :n, modexs, not_yet_set_function_breakpoints)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_msg(conn, "STOPPEDSTEP", "notification")
                end
            elseif msg_cmd=="STEPIN"
                @debug "STEPIN COMMAND"
                ret = our_debug_command(frame, :s, modexs, not_yet_set_function_breakpoints)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_msg(conn, "STOPPEDSTEP", "notification")
                end
            elseif msg_cmd=="STEPOUT"
                @debug "STEPOUT COMMAND"
                ret = our_debug_command(frame, :finish, modexs, not_yet_set_function_breakpoints)

                if ret===nothing
                    @debug "WE ARE SENDING FINISHED"
                    send_msg(conn, "FINISHED", "notification")
                else
                    @debug "NOW WE NEED TO SEND A ON STOP MSG"
                    frame = ret[1]
                    send_msg(conn, "STOPPEDSTEP", "notification")
                end
            end
        end
    finally
        close(conn)
    end
end

end
