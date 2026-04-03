module Moreau_CPU_jll

using Artifacts
import Pkg.Artifacts: create_artifact, remove_artifact
using Downloads
using Libdl
using SHA

const libmoreau_path = Ref{String}("")
const libmoreau_handle = Ref{Ptr{Cvoid}}(C_NULL)

# libmoreau is the symbol used in @ccall — it must resolve to a library path.
libmoreau::String = ""

# Version embedded by gen_artifacts.jl (fallback for manual builds)
const MOREAU_VERSION = Ref{String}("")

function __init__()
    # Priority 1: explicit env var (local development)
    path = get(ENV, "MOREAU_CPU_LIB", "")

    # Priority 2: Julia Artifacts system (authenticated download from Gemfury)
    if isempty(path)
        artifacts_toml = joinpath(pkgdir(Moreau_CPU_jll), "Artifacts.toml")
        if isfile(artifacts_toml)
            hash = artifact_hash("moreau_cpu", artifacts_toml;
                platform=Base.BinaryPlatforms.HostPlatform())
            if hash !== nothing
                if !artifact_exists(hash)
                    _download_from_gemfury(artifacts_toml, hash)
                end
                if artifact_exists(hash)
                    path = _find_lib_in_artifact(artifact_path(hash))
                end
            end
        end
    end

    # Priority 3: system library search
    if isempty(path)
        path = something(
            Libdl.find_library("moreau_cpu"),
            Libdl.find_library("moreau"),
            Libdl.find_library("libmoreau_cpu"),
            Libdl.find_library("libmoreau"),
            "",
        )
    end

    if isempty(path)
        error(
            "Moreau CPU library not found. Either:\n" *
            "  1. Set MOREAU_CPU_LIB to the path of the libmoreau shared library, or\n" *
            "  2. Set GEMFURY_TOKEN and ensure Artifacts.toml has a valid moreau_cpu entry, or\n" *
            "  3. Place libmoreau_cpu on your system library path.",
        )
    end

    global libmoreau = path
    libmoreau_path[] = path
    libmoreau_handle[] = Libdl.dlopen(path)
end

function _find_lib_in_artifact(artifact_dir::String)
    lib_dir = joinpath(artifact_dir, "lib")
    if Sys.isapple()
        candidate = joinpath(lib_dir, "libmoreau_cpu.dylib")
    else
        candidate = joinpath(lib_dir, "libmoreau_cpu.so")
    end
    return isfile(candidate) ? candidate : ""
end

function _download_from_gemfury(artifacts_toml::String, hash::Base.SHA1)
    token = get(ENV, "GEMFURY_TOKEN", "")
    if isempty(token)
        @warn "GEMFURY_TOKEN not set — cannot download Moreau CPU library"
        return
    end

    # Read platform-specific metadata from Artifacts.toml
    meta = artifact_meta("moreau_cpu", artifacts_toml;
        platform=Base.BinaryPlatforms.HostPlatform())
    if meta === nothing
        @warn "No moreau_cpu artifact entry for this platform"
        return
    end

    # Wheel metadata is nested under "wheel" table to avoid Julia treating
    # it as platform tags (which reject special characters in values).
    # We use "wheel" not "download" because Julia auto-fetches from "download" URLs.
    whl = get(meta, "wheel", nothing)
    if whl === nothing
        @warn "Artifacts.toml missing wheel info for moreau_cpu"
        return
    end
    wheel_filename = get(whl, "filename", nothing)
    wheel_sha256 = get(whl, "sha256", nothing)

    if wheel_filename === nothing
        @warn "Artifacts.toml missing wheel filename for moreau_cpu"
        return
    end

    # Find wheel URL on Gemfury PyPI simple index
    url = _find_wheel_on_gemfury(token, "moreau-clib-cpu", wheel_filename)
    if url === nothing
        @warn "Could not find $(wheel_filename) on Gemfury"
        return
    end

    local_wheel = joinpath(tempdir(), wheel_filename)
    try
        @info "Downloading Moreau CPU library..."
        Downloads.download(url, local_wheel)

        # Verify sha256 if present
        if wheel_sha256 !== nothing
            actual = bytes2hex(open(sha256, local_wheel))
            if actual != wheel_sha256
                error("SHA256 mismatch for $(wheel_filename): expected $(wheel_sha256), got $(actual)")
            end
        end

        _install_wheel_as_artifact(local_wheel, hash, "moreau_clib_cpu", "libmoreau_cpu")
    catch e
        @warn "Failed to download Moreau CPU library" exception=(e, catch_backtrace())
    finally
        rm(local_wheel; force=true)
    end
end

"""
    _find_wheel_on_gemfury(token, package, filename) -> Union{String, Nothing}

Query the Gemfury PyPI simple index for `package` and return the authenticated
download URL for `filename`, or `nothing` if not found.
"""
function _find_wheel_on_gemfury(token::String, package::String, filename::String)
    index_url = "https://$(token)@pypi.fury.io/optimalintellect/$(package)/"
    try
        html = String(take!(Downloads.download(index_url, IOBuffer())))
        # Parse hrefs from the simple index HTML
        for m in eachmatch(r"href=\"([^\"]+)\"", html)
            href = m.captures[1]
            if endswith(href, filename) || contains(href, "/$(filename)")
                # If href is relative, make it absolute
                if startswith(href, "http")
                    # Inject token if not present
                    if !contains(href, "@")
                        href = replace(href, "https://" => "https://$(token)@")
                    end
                    return href
                else
                    return "https://$(token)@pypi.fury.io/optimalintellect/$(package)/$(filename)"
                end
            end
        end
    catch e
        @warn "Failed to query Gemfury PyPI index" exception=(e, catch_backtrace())
    end
    return nothing
end

"""
    _install_wheel_as_artifact(wheel, expected_hash, pkg_dir, lib_stem)

Extract a shared library from a wheel (zip) into a Julia artifact.
The wheel contains `{pkg_dir}/{lib_stem}.{so,dylib}` which is extracted
into `lib/` inside the artifact directory.
"""
function _install_wheel_as_artifact(wheel::String, expected_hash::Base.SHA1,
                                     pkg_dir::String, lib_stem::String)
    hash = create_artifact() do dir
        lib_dir = joinpath(dir, "lib")
        mkpath(lib_dir)
        # Extract only the shared library from the wheel (which is a zip)
        run(`unzip -j -o $wheel "$pkg_dir/$lib_stem.*" -d $lib_dir`)
    end
    if hash != expected_hash
        remove_artifact(hash)
        error(
            "Artifact tree hash mismatch: expected $(bytes2hex(expected_hash.bytes)), " *
            "got $(bytes2hex(hash.bytes))"
        )
    end
end

export libmoreau

end # module
