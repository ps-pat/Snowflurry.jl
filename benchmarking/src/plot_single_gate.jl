using JSON
using Plots
using ColorSchemes

include("SnowflurryBenchmarking.jl")

f = open("Project.toml", "r")
lines = readlines(f)
if lines[1] != "name = \"Snowflurry\""
    error("\n\n\tThis project must be activated at the root path of the Snowflurry package.\n\n\tCurrent path is: $(pwd())\n")
end

# Select gate for plotting by uncommenting one line
gate_name="X"
# gate_name="Y"
# gate_name="Z"
# gate_name="Rotation"
# gate_name="RotationX"
# gate_name="RotationY"
# gate_name="Universal"
# gate_name="T"
# gate_name="PHASE"
# gate_name="H"
# gate_name="CNOT"
# gate_name="CZ"
# gate_name="ISWAP"
# gate_name="SWAP"
# gate_name="TOFFOLI"


all_gates=[gate_name]

resultFiles = Dict()

data_tags_color_index = Dict()
data_index = 1

get_tag(s::String, gatename::String) = replace(replace(s, gatename => ""), ".json" => "")

for gate in all_gates
    global data_index

    filepath = joinpath(commonpath, datapath, gate)

    if !isdir(filepath)
        @warn("Path at: $filepath does not exist")
        continue
    end

    resultFiles[gate] = sort(
        [p for p in readdir(filepath) if endswith(p, ".json")])

    if resultFiles[gate] == []
        @warn("No files found for gate: $gate at path: $filepath")
        delete!(resultFiles, gate)
        continue
    end

    println("\nFiles found for gate: $gate")
    for p in resultFiles[gate]
        println("\t$p")
        data_tag = get_tag(p, gate)

        if !haskey(data_tags_color_index, data_tag)
            data_tags_color_index[data_tag] = data_index
            data_index += 1
        end
    end
end

linewidth = 1.5

println("\n\n")

#define ColorScheme for all datasets
myscheme = ColorSchemes.delta
low_val = 0.1
high_val = 0.8

max_num_lines = length(keys(data_tags_color_index))

if max_num_lines > 1
    mycolors = ColorScheme([get(myscheme, i) for i in LinRange(low_val, high_val, max_num_lines)])
else
    mycolors = ColorScheme([get(myscheme, low_val)])
end

for (gates_list, outputname, layout) in [
    (all_gates, all_gates[1], (1, 1))
]

    gr(size=(600, 400), legend=true)

    plot_list = []
    scatter_list = []

    times_per_gate = Dict()
    labels_per_gate = Dict()
    vectorQubits = nothing

    firstPlotDict = Dict()

    for gate in gates_list
        firstPlotDict[gate] = true
    end

    for gate in gates_list
        color_list = nothing

        if !haskey(resultFiles, gate)
            continue
        end

        for (i_line, filepath) in enumerate(resultFiles[gate])

            filename = split(filepath, ".json")[1]

            data_tag = get_tag(filepath, gate)

            println("Processing filename: ", filename, ".json")

            dataDict = JSON.parsefile(joinpath(commonpath, datapath, gate, filepath))

            if !haskey(dataDict, gate)
                @warn ("file $filename doesn't contain benchmarking related to gate type: $gate")
            end

            if color_list === nothing
                color_list = [mycolors[data_tags_color_index[data_tag]]]
            else
                color_list = hcat(color_list, mycolors[data_tags_color_index[data_tag]])
            end

            if firstPlotDict[gate]

                if vectorQubits === nothing
                    vectorQubits = Vector{Float64}(dataDict[gate]["nqubits"])
                end

                times_per_gate[gate] = Vector{Float64}(dataDict[gate]["times"])
                labels_per_gate[gate] = filename


                firstPlotDict[gate] = false

            else

                if length(dataDict[gate]["times"]) == size(times_per_gate[gate], 1)
                    times_per_gate[gate] = hcat(
                        times_per_gate[gate],
                        Vector{Float64}(dataDict[gate]["times"])
                    )

                    if labels_per_gate[gate] isa String
                        labels_per_gate[gate] = hcat(
                            [labels_per_gate[gate]],
                            Vector{String}([filename])
                        )
                    else

                        labels_per_gate[gate] = hcat(
                            labels_per_gate[gate],
                            Vector{String}([filename])
                        )
                    end

                else
                    println("Skipping $filename, wrong number of entries: ")
                    print("Should be: ", size(times_per_gate[gate], 1))
                    println(" instead is: ", length(dataDict[gate]["times"]))

                end
            end

        end

        append!(plot_list, [
            plot(
                vectorQubits,
                times_per_gate[gate],
                linewidth=linewidth,
                label=labels_per_gate[gate],
                title=gate * " Gate",
                yaxis=:log,
                color=reshape([c for c in color_list], 1, length(color_list)),
                xlabel="Qubit count",
                ylabel="Time (ns)",
            )
        ])

        append!(scatter_list, [
            scatter!(
                vectorQubits,
                times_per_gate[gate],
                linewidth=linewidth,
                label=nothing,
                yaxis=:log,
                markercolor=reshape([c for c in color_list], 1, length(color_list)),
                markerstrokewidth=0
            )
        ])
    end

    plot(
        plot_list...,
        layout=layout,
        left_margin=5Plots.mm,
        dpi =400
    )


    println("\noutput path: ", joinpath(commonpath, datapath, string(outputname, ".png")), "\n")

    savefig(joinpath(commonpath, datapath, string(outputname, ".png")))

end
