module Downloads

using ArgTools

include("Curl/Curl.jl")
using .Curl

## Base download API ##

export download

struct Downloader
    multi::Multi
    Downloader() = new(Multi())
end

const DEFAULT_DOWNLOADER = Ref{Union{Downloader, Nothing}}(nothing)
const MAX_CONCURRENCY_DEFAULT_DOWNLOADER = 16
const DEFAULT_DOWNLOADER_QUEUE = Base.Semaphore(MAX_CONCURRENCY_DEFAULT_DOWNLOADER)

function default_downloader()::Downloader
    DEFAULT_DOWNLOADER[] isa Downloader && return DEFAULT_DOWNLOADER[]
    DEFAULT_DOWNLOADER[] = Downloader()
end

const Headers = Union{AbstractVector, AbstractDict}

"""
    download(url, [ output = tempfile() ]; [ headers ]) -> output

        url     :: AbstractString
        output  :: Union{AbstractString, AbstractCmd, IO}
        headers :: Union{AbstractVector, AbstractDict}

Download a file from the given url, saving it to `output` or if not specified,
a temporary path. The `output` can also be an `IO` handle, in which case the
body of the response is streamed to that handle and the handle is returned. If
`output` is a command, the command is run and output is sent to it on stdin.

If the `headers` keyword argument is provided, it must be a vector or dictionary
whose elements are all pairs of strings. These pairs are passed as headers when
downloading URLs with protocols that supports them, such as HTTP/S.
"""
function download(
    url::AbstractString,
    output::Union{ArgWrite, Nothing} = nothing;
    headers::Headers = Pair{String,String}[],
    downloader::Downloader = default_downloader(),
)
    if downloader === default_downloader()
        Base.acquire(DEFAULT_DOWNLOADER_QUEUE)
    end
    yield() # prevents deadlocks, shouldn't be necessary
    try
        arg_write(output) do io
            easy = Easy()
            set_url(easy, url)
            for hdr in headers
                hdr isa Pair{<:AbstractString, <:Union{AbstractString, Nothing}} ||
                    throw(ArgumentError("invalid header: $(repr(hdr))"))
                add_header(easy, hdr)
            end
            add_handle(downloader.multi, easy)
            for buf in easy.buffers
                write(io, buf)
            end
            remove_handle(downloader.multi, easy)
            status = get_response_code(easy)
            status == 200 && return
            if easy.code == Curl.CURLE_OK
                message = get_response_headers(easy)[1]
            else
                message = GC.@preserve easy unsafe_string(pointer(easy.errbuf))
            end
            error(message)
        end
    finally
        if downloader === default_downloader()
            Base.release(DEFAULT_DOWNLOADER_QUEUE)
        end
    end
end

## experimental request API ##

export request, Request, Response

struct Request
    io::IO
    url::String
    headers::Vector{Pair{String,String}}
end

struct Response
    url::String
    status::Int
    response::String
    headers::Vector{Pair{String,String}}
end

function request(req::Request, multi = Multi(), progress = p -> nothing)
    yield() # prevents deadlocks, shouldn't be necessary
    easy = Easy()
    set_url(easy, req.url)
    for hdr in req.headers
        add_header(easy, hdr)
    end
    enable_progress(easy, true)
    add_handle(multi, easy)
    @sync begin
        @async for buf in easy.buffers
            write(req.io, buf)
        end
        @async for prog in easy.progress
            progress(prog)
        end
    end
    remove_handle(multi, easy)
    url = get_effective_url(easy)
    status = get_response_code(easy)
    response, headers = get_response_headers(easy)
    return Response(url, status, response, headers)
end

end # module
