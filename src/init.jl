
# use our own random seed for msg_id so that we
# don't alter the user-visible random state (issue #336)
const IJulia_RNG = MersenneTwister()
uuid4() = repr(Base.Random.uuid4(IJulia_RNG))

const orig_STDIN  = Ref{IO}()
const orig_STDOUT = Ref{IO}()
const orig_STDERR = Ref{IO}()
function __init__()
    srand(IJulia_RNG)
    orig_STDIN[]  = STDIN
    orig_STDOUT[] = STDOUT
    orig_STDERR[] = STDERR
end

const threadid = Array(Int, 128) # sizeof(uv_thread_t) <= 8 on Linux, OSX, Win

# the following constants need to be initialized in init().
const ctx = Ref{Context}()
const publish = Ref{Socket}()
const raw_input = Ref{Socket}()
const requests = Ref{Socket}()
const control = Ref{Socket}()
const heartbeat = Ref{Socket}()
const profile = Dict{String,Any}()
const read_stdout = Ref{Base.PipeEndpoint}()
const read_stderr = Ref{Base.PipeEndpoint}()
const socket_locks = Dict{Socket,ReentrantLock}()

function init(args)
    inited && error("IJulia is already running")
    if length(args) > 0
        merge!(profile, open(JSON.parse,args[1]))
        verbose && println("PROFILE = $profile")
    else
        # generate profile and save
        let port0 = 5678
            merge!(profile, Dict{String,Any}(
                "ip" => "127.0.0.1",
                "transport" => "tcp",
                "stdin_port" => port0,
                "control_port" => port0+1,
                "hb_port" => port0+2,
                "shell_port" => port0+3,
                "iopub_port" => port0+4,
                "key" => uuid4()
            ))
            fname = "profile-$(getpid()).json"
            println("connect ipython with --existing $(pwd())/$fname")
            open(fname, "w") do f
                JSON.print(f, profile)
            end
        end
    end

    if !isempty(profile["key"])
        signature_scheme = get(profile, "signature_scheme", "hmac-sha256")
        isempty(signature_scheme) && (signature_scheme = "hmac-sha256")
        signature_scheme = split(signature_scheme, "-")
        if signature_scheme[1] != "hmac" || signature_scheme[2] != "sha256"
            error("unrecognized signature_scheme $signature_scheme")
        end
        push!(hmacstate,HMAC.HMACState(profile["key"]))
    end

    ctx[] = Context()
    publish[] = Socket(ctx[], PUB)
    raw_input[] = Socket(ctx[], ROUTER)
    requests[] = Socket(ctx[], ROUTER)
    control[] = Socket(ctx[], ROUTER)
    heartbeat[] = Socket(ctx[], ROUTER)
    bind(publish[], "$(profile["transport"])://$(profile["ip"]):$(profile["iopub_port"])")
    bind(requests[], "$(profile["transport"])://$(profile["ip"]):$(profile["shell_port"])")
    bind(control[], "$(profile["transport"])://$(profile["ip"]):$(profile["control_port"])")
    bind(raw_input[], "$(profile["transport"])://$(profile["ip"]):$(profile["stdin_port"])")
    bind(heartbeat[], "$(profile["transport"])://$(profile["ip"]):$(profile["hb_port"])")

    # associate a lock with each socket so that multi-part messages
    # on a given socket don't get inter-mingled between tasks.
    for s in (publish[], raw_input[], requests[], control[], heartbeat[])
        socket_locks[s] = ReentrantLock()
    end

    start_heartbeat(heartbeat[])
    read_stdout[], = redirect_stdout()
    if capture_stderr
        read_stderr[], = redirect_stderr()
    end

    send_status("starting")
    global inited = true
end
