using Snowflurry

abstract type Transpiler end

transpile(t::Transpiler,::QuantumCircuit)::QuantumCircuit= 
    throw(NotImplementedError(:transpile,t))

"""
    SequentialTranspiler(Vector{<:Transpiler})
    
Composite transpiler object which is constructed from an array 
of `Transpiler` stages. Calling 
    `transpile(::SequentialTranspiler,::QuantumCircuit)`
will apply each stage in sequence to the input circuit and return
a transpiled output circuit. The result of the input and output 
circuit on any arbitrary state `Ket` is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=SequentialTranspiler([CompressSingleQubitGatesTranspiler(),CastToPhaseShiftAndHalfRotationXTranspiler()]);

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[sigma_x(1),hadamard(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──X────H──
               
q[2]:──────────
               



julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z────X_90────Z_90────X_m90────Z──
                                                              
q[2]:───────────────────────────────────
                                                              



julia> circuit = QuantumCircuit(qubit_count = 3, gates=[sigma_x(1),sigma_y(1),control_x(2,3),phase_shift(1,π/3)])
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──X────Y─────────Rz(1.0472)──

q[2]:────────────*────────────────
                 |                
q[3]:────────────X────────────────
                                  



julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──Rz(-2.0944)───────
                         
q[2]:─────────────────*──
                      |  
q[3]:─────────────────X──
                         



```
"""  
struct SequentialTranspiler<:Transpiler
    stages::Vector{<:Transpiler}

    function SequentialTranspiler(stages::Vector{<:Transpiler})
        @assert length(stages)>0

        new(stages)
    end
end

function transpile(transpiler::SequentialTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    for stage in transpiler.stages
        circuit = transpile(stage, circuit)
    end

    return circuit
end

struct CompressSingleQubitGatesTranspiler<:Transpiler end

# convert a single-target gate to a Universal gate
function as_universal_gate(target::Integer,op::AbstractOperator)::Gate{Universal}
    @assert size(op)==(2,2)
    
    matrix=get_matrix(op)

    #find global phase offset angle
    alpha=atan(imag(matrix[1,1]),real(matrix[1,1]) )
    
    #remove global offset
    matrix*=exp(-im*alpha)
    
    theta=(2*acos(real(matrix[1,1])))

    if (isapprox(theta,0.,atol=1e-6))||(isapprox(theta,2*π,atol=1e-6))
        lambda=0
        phi   =real(exp(-im*π/2)log( matrix[2,2]/cos(theta/2)))
    else
        lambda=real(exp(-im*π/2)*log(-matrix[1,2]/sin(theta/2)))
        phi   =real(exp(-im*π/2)*log( matrix[2,1]/sin(theta/2)))
    end

    # test if universal gate can be constructed from this operator
    @assert isapprox(real(matrix[2,2]),real(exp(im*(lambda+phi))*cos(theta/2)),atol=1e-6)
    @assert isapprox(imag(matrix[2,2]),imag(exp(im*(lambda+phi))*cos(theta/2)),atol=1e-6)

    return universal(target, theta, phi, lambda)
end

# compress (combine) several single-target gates with a common target to a Universal gate
# does not assert gates having common target
function unsafe_compress_to_universal(gates::Vector{Gate}, target::Int)::Gate{Universal}
    combined_op=eye()

    for gate in gates
        symbol = get_gate_symbol(gate)
        @assert get_num_connected_qubits(symbol)==1 ("Received gate with multiple targets: $(gate)")
        targets=get_connected_qubits(gate)
        @assert length(targets)==1 ("Received gate with multiple targets: $gate")
        @assert targets[1]==target ("Gates in array do not share common target")

        combined_op=get_operator(get_gate_symbol(gate))*combined_op
    end

    return as_universal_gate(target,combined_op)
end

set_of_rz_gates=[
    Z90,
    ZM90,
    SigmaZ,
    Pi8,
    Pi8Dagger,
    PhaseShift
]

is_multi_target(symbol::AbstractGateSymbol) = get_num_connected_qubits(symbol)>1
is_multi_target(gate::Gate) = is_multi_target(get_gate_symbol(gate))

function is_not_rz_gate(::Gate{SymbolType})::Bool where SymbolType<:AbstractGateSymbol
    return !(SymbolType in set_of_rz_gates)
end

is_multi_target_or_not_rz(gate::Gate)= is_multi_target(gate) || is_not_rz_gate(gate)

function find_and_compress_blocks(
    circuit::QuantumCircuit,
    is_boundary::Function,
    compression_function::Function
    )::QuantumCircuit

    gates=get_circuit_gates(circuit)

    qubit_count=get_num_qubits(circuit)
    output_circuit=QuantumCircuit(qubit_count=qubit_count)

    # Split circuit into blocks of single-target gates that
    # share a common target, separated by boundaries. 
    # What constitutes a boundary is determined using 
    # the `is_boundary` input. 
    # Common-target gates inside a block can be combined, 
    # but not with gates in another block, as a boundary
    # is present between them. 
    # If first gate is a boundary, first block is left empty. 

    ######################################################
    #
    #  blocks_per_target is a Dict
    #   where:
    #       - keys    : the target numbers of qubits in circuit
    #       - values  : Vector{Vector{i_gate::Int}}
    #                   
    #           where:   - i_gate  : the gate's index in 'gates'
    #                    
    #                    - Vector{i_gate} : a block of common-target 
    #                       gates, with no boundary between them
    #
    #                    - Vector{Vector{i_gate}} : list of 
    #                       consecutive blocks, each separated by 
    #                       an entry in 'boundaries'   
    #     
    blocks_per_target=Dict{Int,Vector{Vector{Int}}}(Dict())

    #initialize empty blocks at all targets
    for target in 1:qubit_count
        blocks_per_target[target]=[[]]
    end

    ######################################################
    #
    #  boudaries is a Vector of Tuple{i_gate::Int,targets::Int}
    #  where:
    #       i_gate  : the gate's index in 'gates'
    #       targets : the targets of gate[i_gate]
    #               
    boundaries=Vector{Tuple{Int,Vector{Int}}}([]) 

    current_block=[1 for _ in 1:qubit_count]

    can_be_placed=Dict(target=>[true] for target in 1:qubit_count)

    placed_gates=[false for _ in 1:length(gates)]

    for (i_gate,gate) in enumerate(gates)
        targets=get_connected_qubits(gate)

        if is_boundary(gate)

            # add group boundary at each of those targets
            push!(boundaries,(i_gate,targets))
            
            for target in targets
                # create new empty group at those targets
                push!(blocks_per_target[target],[])

                # disallow placement until boundary is passed
                push!(can_be_placed[target],false)
            end
                
        else
            target=targets[1]
            
            # inside a group, common-target gates are put in blocks.
            # append gate to last block
            push!(blocks_per_target[target][end],i_gate)
        end
    end

    # reverse so pop! returns first boundary
    boundaries=reverse(boundaries)

    iteration_count=0

    #build compressed circuit
    while true
        iteration_count+=1

        #place allowed blocks
        for target in 1:qubit_count

            block_index=current_block[target]

            if can_be_placed[target][block_index]

                block=blocks_per_target[target][block_index]

                gates_block::Vector{Gate} = [ convert(Gate, gates[i]) for i in block]

                if length(block)>1
                    push!(output_circuit, compression_function(gates_block, target))
                    
                    for i_gate in block
                        placed_gates[i_gate]=true
                    end
                elseif length(block)==1
                    #no need to compress individual gate
                    push!(output_circuit,gates_block[1])

                    placed_gates[block[1]]=true
                end

                can_be_placed[target][block_index]=false
            end
        end

        if !isempty(boundaries)
            # pass boundary
            (i_gate,targets)=pop!(boundaries)

            push!(output_circuit,gates[i_gate])
            placed_gates[i_gate]=true

            #unlock next blocks for those targets (boundary passed)
            for target in targets
                current_block[target]+=1
                can_be_placed[target][current_block[target]]=true
            end

        end

        if all(placed_gates)
            break
        end

        @assert iteration_count<length(gates)+1 ("Failed to construct output")
    end

    return output_circuit
end


"""
    transpile(::CompressSingleQubitGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CompressSingleQubitGatesTranspiler` transpiler stage 
which gathers all single-qubit gates sharing a common target in an input 
circuit and combines them into single `Universal` gates in a new circuit.
Gates ordering may differ when gates are applied to different qubits, 
but the result of the input and output circuit on any arbitrary state `Ket` 
is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=CompressSingleQubitGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[sigma_x(1),sigma_y(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──X────Y──
               
q[2]:──────────
               



julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──U(θ=0.0000,ϕ=3.1416,λ=0.0000)──
                                      
q[2]:─────────────────────────────────
                                      



julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 3, gates=[sigma_x(1),sigma_y(1),control_x(2,3),phase_shift(1,π/3)])
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──X────Y─────────Rz(1.0472)──
                                  
q[2]:────────────*────────────────
                 |                
q[3]:────────────X────────────────
                                  



julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──U(θ=0.0000,ϕ=-2.0944,λ=0.0000)───────
                                            
q[2]:────────────────────────────────────*──
                                         |  
q[3]:────────────────────────────────────X──
                                            




julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(::CompressSingleQubitGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit   
    return find_and_compress_blocks(circuit,is_multi_target,unsafe_compress_to_universal)
end

function cast_to_cz(gate::AbstractGateSymbol, _::Vector{Int})
    throw(NotImplementedError(:cast_to_cz,gate))
end

function cast_to_cz(::Swap, connected_qubits::Vector{Int})::AbstractVector{Gate}
    @assert length(connected_qubits) == 2
    q1 = connected_qubits[1]
    q2 = connected_qubits[2]

    return Vector{Gate}([
        y_minus_90(q2),
        control_z(q1, q2),
        y_minus_90(q1),
        y_90(q2),
        control_z(q1, q2),
        y_90(q1),
        y_minus_90(q2),
        control_z(q1, q2),
        y_90(q2),
    ])
end

struct CastSwapToCZGateTranspiler <: Transpiler end

"""
    transpile(::CastSwapToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastSwapToCZGateTranspiler` transpiler stage which
expands all Swap gates into `CZ` gates and single-qubit gates. The result of the
input and output circuit on any arbitrary state `Ket` is unchanged (up to a
global phase).

# Examples
```jldoctest
julia> transpiler=CastSwapToCZGateTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[swap(1, 2)])
Quantum Circuit Object:
   qubit_count: 2
q[1]:──☒──
       |
q[2]:──☒──

julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:───────────*────Y_m90────────────*────Y_90─────────────*──────────
                |                     |                     |          
q[2]:──Y_m90────Z─────────────Y_90────Z────────────Y_m90────Z────Y_90──
                                              

```
"""
function transpile(::CastSwapToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{Swap}
            push!(output, cast_to_cz(get_gate_symbol(gate), get_connected_qubits(gate))...)
        else
            push!(output, gate)
        end
    end

    return output
end

function cast_to_cz(::ControlX, connected_qubits::Vector{Int})::AbstractVector{Gate}
    @assert length(connected_qubits) == 2
    q1 = connected_qubits[1]
    q2 = connected_qubits[2]

    return Vector{Gate}([
        hadamard(q2),
        control_z(q1, q2),
        hadamard(q2),
    ])
end

struct CastCXToCZGateTranspiler <: Transpiler end

"""
    transpile(::CastCXToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastCXToCZGateTranspiler` transpiler stage which
expands all `CX` gates into `CZ` and `Hadamard` gates. The result of the
input and output circuit on any arbitrary state `Ket` is unchanged (up to a
global phase).

# Examples
```jldoctest
julia> transpiler=CastCXToCZGateTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[control_x(1, 2)])
Quantum Circuit Object:
   qubit_count: 2
q[1]:──*──
       |
q[2]:──X──

julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2
q[1]:───────*───────
            |
q[2]:──H────Z────H──
```
"""
function transpile(::CastCXToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{ControlX}
            push!(output, cast_to_cz(get_gate_symbol(gate), get_connected_qubits(gate))...)
        else
            push!(output, gate)
        end
    end

    return output
end

function cast_to_cz(::ISwap, connected_qubits::Vector{Int})::AbstractVector{Gate}
    @assert length(connected_qubits) == 2
    q1 = connected_qubits[1]
    q2 = connected_qubits[2]

    return Vector{Gate}([
        y_minus_90(q1),
        x_minus_90(q2),
        control_z(q1, q2),
        y_90(q1),
        x_minus_90(q2),
        control_z(q1, q2),
        y_90(q1),
        x_90(q2),
    ])
end

struct CastISwapToCZGateTranspiler <: Transpiler end

"""
    transpile(::CastISwapToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastISwapToCZGateTranspiler` transpiler stage which
expands all `ISwap` gates into `CZ` gates and single-qubit gates. The result of the
input and output circuit on any arbitrary state `Ket` is unchanged (up to a
global phase).

# Examples
```jldoctest
julia> transpiler=CastISwapToCZGateTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[iswap(1, 2)])
Quantum Circuit Object:
   qubit_count: 2
q[1]:──x──
       |
q[2]:──x──

julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Y_m90─────────────*────Y_90─────────────*────Y_90──────────
                         |                     |                  
q[2]:───────────X_m90────Z────────────X_m90────Z────────────X_90──
                                                                  

```
"""
function transpile(::CastISwapToCZGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{ISwap}
            push!(output, cast_to_cz(get_gate_symbol(gate), get_connected_qubits(gate))...)
        else
            push!(output, gate)
        end
    end

    return output
end

function cast_to_cx(gate::Toffoli, connected_qubits::Vector{Int})::AbstractVector{Gate}
    @assert length(connected_qubits) == 3
    q1 = connected_qubits[1]
    q2 = connected_qubits[2]
    q3 = connected_qubits[3]

    h(q) = hadamard(q)
    cnot(q1, q2) = control_x(q1, q2)
    t(q) = pi_8(q)
    t_dag(q) = pi_8_dagger(q)

    return Vector{Gate}([
        h(q3),
        cnot(q2,q3),
        t_dag(q3),
        cnot(q1, q3),
        t(q3),
        cnot(q2, q3),
        t_dag(q3),
        cnot(q1, q3),
        t(q2),
        t(q3),
        cnot(q1, q2),
        hadamard(q3),
        t(q1),
        t_dag(q2),
        cnot(q1, q2),
    ])
end

struct CastToffoliToCXGateTranspiler <: Transpiler end

"""
    transpile(::CastToffoliToCXGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastToffoliToCXGateTranspiler` transpiler stage which
expands all Toffoli gates into `CX` gates and single-qubit gates. The result of the
input and output circuit on any arbitrary state `Ket` is unchanged (up to a
global phase).

# Examples
```jldoctest
julia> transpiler=CastToffoliToCXGateTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 3, gates=[toffoli(1, 2, 3)])
Quantum Circuit Object:
   qubit_count: 3
q[1]:──*──
       |
q[2]:──*──
       |
q[3]:──X──

julia> transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──────────────────*────────────────────*──────────────*─────────T──────────*──
                       |                    |              |                    |  
q[2]:───────*──────────|─────────*──────────|────T─────────X──────────────T†────X──
            |          |         |          |                                      
q[3]:──H────X────T†────X────T────X────T†────X─────────T─────────H──────────────────
                                                                                   

```
"""
function transpile(::CastToffoliToCXGateTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{Toffoli}
            push!(output, cast_to_cx(get_gate_symbol(gate),get_connected_qubits(gate))...)
        else
            push!(output, gate)
        end
    end

    return output
end

struct CastToPhaseShiftAndHalfRotationXTranspiler<:Transpiler 
    atol::Real
end

CastToPhaseShiftAndHalfRotationXTranspiler()=CastToPhaseShiftAndHalfRotationXTranspiler(1e-6)

function simplify_rz_gate(
    gate::Gate{PhaseShift};
    atol=1e-6)::Union{Gate, Nothing}

    target = get_connected_qubits(gate)[1]
    phase_angle = get_gate_symbol(gate).phi; 
    
    phase_angle=phase_angle%(2*π)

    if isapprox(phase_angle,π/2,atol=atol) || isapprox(phase_angle,-3*π/2,atol=atol)
        return z_90(target)

    elseif isapprox(abs(phase_angle),π,atol=atol) 
        return sigma_z(target)

    elseif isapprox(phase_angle,-π/2,atol=atol) || isapprox(phase_angle,3*π/2,atol=atol)
        return z_minus_90(target)

    elseif isapprox(phase_angle,π/4,atol=atol) 
        return pi_8(target)
        
    elseif isapprox(phase_angle,-π/4,atol=atol) 
        return pi_8_dagger(target)

    elseif isapprox(phase_angle,0.,atol=atol) 
        return nothing

    else
        return phase_shift(target,phase_angle)
    
    end
end

function simplify_rx_gate(
    gate::Gate{RotationX};
    atol=1e-6)::Union{Gate, Nothing}

    target = get_connected_qubits(gate)[1]
    theta = get_gate_symbol(gate).theta
    
    if isapprox(theta,π/2,atol=atol) 
        return x_90(target)

    elseif isapprox(abs(theta),π,atol=atol) 
        return sigma_x(target)

    elseif isapprox(theta,-π/2,atol=atol) 
        return x_minus_90(target)
    
    elseif isapprox(theta,0.,atol=atol) 
        return nothing

    else
        return rotation_x(target,theta)
    
    end
end


function cast_to_phase_shift_and_half_rotation_x(gate::Universal, target::Int;atol=1e-6)
    params=get_gate_parameters(gate)
   
    theta   =params["theta"]
    phi     =params["phi"]
    lambda  =params["lambda"]

    gate_array=Vector{Gate}([])

    if !(isapprox(lambda,0.,atol=atol))
        push!(
            gate_array,
            simplify_rz_gate(phase_shift(target,lambda);atol=atol)
        )
    end

    if !(isapprox(theta,0.,atol=atol))
        push!(gate_array,x_90(target))
        push!(
            gate_array,
            simplify_rz_gate(phase_shift(target,theta);atol=atol)
        )
        push!(gate_array,x_minus_90(target))
    end

    if !(isapprox(phi,0.,atol=atol))
        push!(
            gate_array,
            simplify_rz_gate(phase_shift(target,phi);atol=atol)
        )
    end

    return gate_array
end

"""
    transpile(::CastToPhaseShiftAndHalfRotationXTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastToPhaseShiftAndHalfRotationXTranspiler` transpiler stage 
which converts all single-qubit gates in an input circuit and converts them 
into combinations of `PhaseShift` and `RotationX` with angle π/2 in an output 
circuit. For any gate in the input circuit, the number of gates in the 
output varies between zero and 5. The result of the input and output 
circuit on any arbitrary state `Ket` is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=CastToPhaseShiftAndHalfRotationXTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[sigma_x(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──X──
          
q[2]:─────
          



julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z────X_90────Z────X_m90──
                                                 
q[2]:───────────────────────────
                                                 



julia> circuit = QuantumCircuit(qubit_count = 2, gates=[sigma_y(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Y──
          
q[2]:─────
          



julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z_90────X_90────Z────X_m90────Z_90──
                                           
q[2]:──────────────────────────────────────
                                           



julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[universal(1,0.,0.,0.)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──U(θ=0.0000,ϕ=0.0000,λ=0.0000)──
                                      
q[2]:─────────────────────────────────
                                      



julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:
     



julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(transpiler_stage::CastToPhaseShiftAndHalfRotationXTranspiler, circuit::QuantumCircuit)::QuantumCircuit

    gates=get_circuit_gates(circuit)
    
    qubit_count=get_num_qubits(circuit)
    output_circuit=QuantumCircuit(qubit_count=qubit_count)

    atol=transpiler_stage.atol

    for gate in gates

        targets=get_connected_qubits(gate)

        if length(targets)>1
            push!(output_circuit,gate)
        else
            if !(gate isa Snowflurry.Gate{Universal})
                gate=get_gate_symbol(as_universal_gate(targets[1],get_operator(get_gate_symbol(gate))))
            else
                gate=get_gate_symbol(gate)
            end

            gate_array=cast_to_phase_shift_and_half_rotation_x(gate, targets[1];atol=atol)
            push!(output_circuit, gate_array...)
        end
    end

    return output_circuit
end

# Cast a Universal gate as U=Rz(β)Rx(γ)Rz(δ)
# See: Nielsen and Chuang, Quantum Computation and Quantum Information, p175.
function cast_to_rz_rx_rz(gate::Universal, target::Int)::Vector{Gate}
    params=get_gate_parameters(gate)
   
    γ=params["theta"]
    β=params["phi"]+π/2
    δ=params["lambda"]-π/2
   
    gate_array=Vector{Gate}([])

    push!(gate_array,phase_shift(target,δ))

    push!(gate_array,rotation_x(target,γ))

    push!(gate_array,phase_shift(target,β))

    return gate_array
end

struct CastUniversalToRzRxRzTranspiler<:Transpiler end

"""
    transpile(::CastUniversalToRzRxRzTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastUniversalToRzRxRzTranspiler` transpiler stage 
which finds `Universal` gates in an input circuit and casts 
them into a sequence of `PhaseShift` (Rz), `RotationX` (Rx) and 
`PhaseShift` (Rz) gates in a new circuit.
The result of the input and output circuit on any arbitrary state `Ket` 
is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=CastUniversalToRzRxRzTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[universal(1,π/2,π/4,π/8)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──U(θ=1.5708,ϕ=0.7854,λ=0.3927)──
                                      
q[2]:─────────────────────────────────
                                      

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(-1.1781)────Rx(1.5708)────Rz(2.3562)──
                                                
q[2]:───────────────────────────────────────────
                                                

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[universal(1,0,π/4,0)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──U(θ=0.0000,ϕ=0.7854,λ=0.0000)──
                                      
q[2]:─────────────────────────────────
                                      

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(-1.5708)────Rx(0.0000)────Rz(2.3562)──
                                                
q[2]:───────────────────────────────────────────
                                                

julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(::CastUniversalToRzRxRzTranspiler, circuit::QuantumCircuit)::QuantumCircuit

    gates=get_circuit_gates(circuit)
    
    qubit_count=get_num_qubits(circuit)
    output_circuit=QuantumCircuit(qubit_count=qubit_count)

    for gate in gates

        targets=get_connected_qubits(gate)

        if length(targets)>1
            push!(output_circuit,gate)
        else
            if !(gate isa Snowflurry.Gate{Universal})
                gate=get_gate_symbol(as_universal_gate(targets[1],get_operator(get_gate_symbol(gate))))
            else
                gate=get_gate_symbol(gate)
            end

            gate_array=cast_to_rz_rx_rz(gate, targets[1])
            push!(output_circuit, gate_array...)
        end
    end

    return output_circuit
end

function cast_rx_to_rz_and_half_rotation_x(gate::Gate{RotationX})::Vector{Gate}
    target=get_connected_qubits(gate)[1]

    theta   = get_gate_symbol(gate).theta

    gate_array=Vector{Gate}([])

    push!(gate_array,z_90(target))
    push!(gate_array,x_90(target))
    push!(gate_array,phase_shift(target,theta))
    push!(gate_array,x_minus_90(target))
    push!(gate_array,z_minus_90(target))

    return gate_array
end

struct CastRxToRzAndHalfRotationXTranspiler<:Transpiler end


"""
    transpile(::CastRxToRzAndHalfRotationXTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CastRxToRzAndHalfRotationXTranspiler` transpiler stage 
which finds `RotationX(θ)` gates in an input circuit and converts (casts) 
them into a sequence of gates: `Z90`,`X90`,`PhaseShift(θ)`,`XM90`,`ZM90` in a new circuit.
The result of the input and output circuit on any arbitrary state `Ket` 
is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=CastRxToRzAndHalfRotationXTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[rotation_x(1,π/8)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rx(0.3927)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z_90────X_90────Rz(0.3927)────X_m90────Z_m90──
                                                     
q[2]:────────────────────────────────────────────────
                                                     

julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(::CastRxToRzAndHalfRotationXTranspiler, circuit::QuantumCircuit)::QuantumCircuit

    gates=get_circuit_gates(circuit)
    
    qubit_count=get_num_qubits(circuit)
    output_circuit=QuantumCircuit(qubit_count=qubit_count)

    for gate in gates
        
        if gate isa Snowflurry.Gate{RotationX}
            gate_array=cast_rx_to_rz_and_half_rotation_x(gate)
            push!(output_circuit, gate_array...)
        else
            push!(output_circuit,gate)
        end
    end

    return output_circuit
end


struct SimplifyRxGatesTranspiler<:Transpiler 
    atol::Real
end

SimplifyRxGatesTranspiler()=SimplifyRxGatesTranspiler(1e-6)

"""
    transpile(::SimplifyRxGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `SimplifyRxGatesTranspiler` transpiler stage 
which finds `RotationX` gates in an input circuit and according to its 
angle theta, casts them to one of the right-angle `RotationX` gates, 
e.g., `SigmaX`, `X90`, or `XM90`. In the case where `theta≈0.`, the gate is removed.
The result of the input and output circuit on any arbitrary state `Ket` is 
unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=SimplifyRxGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[rotation_x(1,pi/2)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rx(1.5708)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──X_90──
             
q[2]:────────
             

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[rotation_x(1,pi)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rx(3.1416)──
                   
q[2]:──────────────
                   


julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──X──
          
q[2]:─────
          

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[rotation_x(1,0.)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rx(0.0000)──
                   
q[2]:──────────────
                   


julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:
     



julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(transpiler_stage::SimplifyRxGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    atol=transpiler_stage.atol

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{RotationX}
            new_gate=simplify_rx_gate(
                gate,
                atol=atol
            )

            if !isnothing(new_gate)
                push!(output,new_gate)
            end
        else
            push!(output, gate)
        end
    end

    return output
end

struct SwapQubitsForAdjacencyTranspiler<:Transpiler 
    connectivity::AbstractConnectivity
end

function remap_qubits_to_adjacent(
    connected_qubits::Vector{Int},
    connectivity::AbstractConnectivity
    )::Tuple{Vector{Int},Vector{Int},Vector{Vector{Int}}}
    
    min_qubit=minimum(connected_qubits)

    distances = [get_qubits_distance(min_qubit,pos,connectivity) for pos in connected_qubits]

    sorting_order=sortperm(distances)

    # this contains an array of consecutive elements,
    # in the same unsorted order as the input,
    # meaning: sortperm(connected_qubits)==sortperm(mapped_indices)
    mapped_indices=sortperm(sorting_order)
    
    # create paths so that connected_qubits become adjacent on this connectivity
    paths=[[connected_qubits[sorting_order[1]]]]
    for pos in connected_qubits[sorting_order[2:end]]
        path = path_search(min_qubit, pos, connectivity)
        push!(paths, path[1:end-1])
        min_qubit = path[end-1]
    end

    adjacent_mapping=[path[end] for path in paths]
    paths=[path[1:end-1] for path in paths]

    # reorder in same unsorted order as input
    adjacent_mapping = adjacent_mapping[mapped_indices]
    paths = paths[mapped_indices]

    return (adjacent_mapping, sorting_order, paths)
end

function remap_connections_using_swaps(
    gates_block::Vector{<: Gate},
    adjacent_mapping::Vector{Int},
    paths::Vector{Vector{Int}},
    )::Vector{Gate}

    for (current_qubit_num,path) in zip(adjacent_mapping,paths)
        
        while !isempty(path)
            next_pos=pop!(path)
            
            # surround current gates_block with swap gates 
            # to bring one step closer
            gates_block=vcat(
                swap(current_qubit_num, next_pos),
                gates_block,
                swap(current_qubit_num, next_pos)
            )

            current_qubit_num = next_pos
        end
    end

    return gates_block
end

"""
    transpile(::SwapQubitsForAdjacencyTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `SwapQubitsForAdjacencyTranspiler` transpiler stage 
which adds `Swap` gates around multi-qubit gates so that the 
final `Operator` acts on adjacent qubits. The result of the input 
and output circuit on any arbitrary state `Ket` is unchanged 
(up to a global phase).

# Examples
```jldoctest
julia> transpiler=SwapQubitsForAdjacencyTranspiler(LineConnectivity(6));

julia> circuit = QuantumCircuit(qubit_count = 6, gates=[toffoli(4,6,1)])
Quantum Circuit Object:
   qubit_count: 6 
q[1]:──X──
       |  
q[2]:──|──
       |  
q[3]:──|──
       |  
q[4]:──*──
       |  
q[5]:──|──
       |  
q[6]:──*──
          




julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 6 
q[1]:───────────────────────────X───────────────────────────
                                |                           
q[2]:───────☒───────────────────*───────────────────☒───────
            |                   |                   |       
q[3]:──☒────☒──────────────☒────*────☒──────────────☒────☒──
       |                   |         |                   |  
q[4]:──☒──────────────☒────☒─────────☒────☒──────────────☒──
                      |                   |                 
q[5]:────────────☒────☒───────────────────☒────☒────────────
                 |                             |            
q[6]:────────────☒─────────────────────────────☒────────────
                                                            



julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(
    transpiler::SwapQubitsForAdjacencyTranspiler, 
    circuit::QuantumCircuit
    )::QuantumCircuit

    gates = get_circuit_gates(circuit)
    
    qubit_count = get_num_qubits(circuit)
    output_circuit = QuantumCircuit(qubit_count = qubit_count)

    for gate in gates
        
        connected_qubits = get_connected_qubits(gate)

        if length(connected_qubits) > 1

            (adjacent_mapping, sorting_order, paths) = 
                remap_qubits_to_adjacent(connected_qubits, transpiler.connectivity)
            
            mapping_dict=Dict(
                [
                    old_number => new_number for (old_number, new_number) in 
                        zip(connected_qubits, adjacent_mapping)
                ]
            )
    
            gates_block = [move_gate(gate, mapping_dict)]

            @assert get_connected_qubits(gates_block[1]) == adjacent_mapping (
                "Failed to construct gate: $(typeof((gates_block[1])))")

            # leaving first (minimum) qubit unchanged,
            # add swaps starting from the farthest qubit
            adjacent_mapping = adjacent_mapping[reverse(sorting_order[2:end])]
            paths = paths[reverse(sorting_order[2:end])]
            
            gates_block = remap_connections_using_swaps(
                gates_block,
                adjacent_mapping,
                paths
            )

            push!(output_circuit, gates_block...)
        else
            # no effect for single-target gate
            push!(output_circuit, gate)
        end
    end

    return output_circuit
end

struct SimplifyRzGatesTranspiler<:Transpiler 
    atol::Real
end

SimplifyRzGatesTranspiler()=SimplifyRzGatesTranspiler(1e-6)

"""
    transpile(::SimplifyRzGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `SimplifyRzGatesTranspiler` transpiler stage 
which finds `PhaseShift` gates in an input circuit and according to its 
phase angle phi, casts them to one of the right-angle `RotationZ` gates, 
e.g., `SigmaZ`, `Z90`, `ZM90`, `Pi8` or `Pi8Dagger`. In the case where `phi≈0.`, the 
gate is removed. The result of the input and output circuit on any 
arbitrary state `Ket` is unchanged (up to a global phase). The tolerance 
used for `Base.isapprox()` in each case can be set by passing an optional 
argument to the `Transpiler`, e.g:
`transpiler=SimplifyRzGatesTranspiler(1.0e-10)`

# Examples
```jldoctest
julia> transpiler=SimplifyRzGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[phase_shift(1,pi/2)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(1.5708)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z_90──
             
q[2]:────────
             

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[phase_shift(1,pi)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(3.1416)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z──
          
q[2]:─────
          

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[phase_shift(1,0.)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(0.0000)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:
     



julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(
    transpiler_stage::SimplifyRzGatesTranspiler, 
    circuit::QuantumCircuit
    )::QuantumCircuit

    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    atol=transpiler_stage.atol

    for gate in get_circuit_gates(circuit)
        if gate isa Snowflurry.Gate{PhaseShift}
            new_gate=simplify_rz_gate(
                gate,
                atol=atol
            )
            if !isnothing(new_gate)
                push!(output,new_gate)
            end
        else
            push!(output, gate)
        end
    end

    return output
end

struct CompressRzGatesTranspiler<:Transpiler end

# construct a PhaseShift gate from an input Operator
function as_phase_shift_gate(target::Integer,op::AbstractOperator)::Gate{PhaseShift}
    @assert size(op)==(2,2) ("Received multi-target Operator: $op")
    
    matrix=get_matrix(op)

    @assert matrix[1,2]≈ComplexF64(0.) ("Failed to build a PhaseShift gate from input Operator: $op")
    @assert matrix[2,1]≈ComplexF64(0.) ("Failed to build a PhaseShift gate from input Operator: $op")

    #find global phase offset angle
    alpha=atan(imag(matrix[1,1]),real(matrix[1,1]) )
    
    #remove global offset
    matrix*=exp(-im*alpha)
    
    #find relative phase offset angle
    phi=atan(imag(matrix[2,2]),real(matrix[2,2]) )

    return phase_shift(target, phi)
end

# compress (combine) several Rz-type gates with a common target to a PhaseShift gate
# Warning: does not assert gates having common target
function unsafe_compress_to_rz(gates::Vector{Gate}, target::Int)::Gate{PhaseShift}
    combined_op=eye()

    for gate in gates
        combined_op=get_operator(get_gate_symbol(gate))*combined_op
    end
    
    return as_phase_shift_gate(target,combined_op)
end

"""
    transpile(::CompressRzGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `CompressRzGatesTranspiler` transpiler stage 
which gathers all Rz-type gates sharing a common target in an input 
circuit and combines them into single PhaseShift gate in a new circuit.
Gates ordering may differ when gates are applied to different qubits, 
but the result of the input and output circuit on any arbitrary state `Ket` 
is unchanged (up to a global phase).

# Examples
```jldoctest
julia> transpiler=CompressRzGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[sigma_z(1),z_90(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Z────Z_90──
                  
q[2]:─────────────
                  

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(-1.5708)──
                    
q[2]:───────────────
                    

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 3, gates=[sigma_z(1),pi_8(1),control_x(2,3),z_minus_90(1)])
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──Z────T─────────Z_m90──
                             
q[2]:────────────*───────────
                 |           
q[3]:────────────X───────────
                             

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 3 
q[1]:──Rz(2.3562)───────
                        
q[2]:────────────────*──
                     |  
q[3]:────────────────X──
                        

julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(::CompressRzGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

    if length(get_circuit_gates(circuit))==1
        # no compression needed for individual gate
        return circuit
    end
    
    return find_and_compress_blocks(circuit,is_multi_target_or_not_rz,unsafe_compress_to_rz)
end

struct TrivialTranspiler<:Transpiler end

transpile(::TrivialTranspiler, circuit::QuantumCircuit)::QuantumCircuit=circuit 

struct RemoveSwapBySwappingGatesTranspiler <: Transpiler end

"""
    transpile(::RemoveSwapBySwappingGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Removes the `Swap` gates from the `circuit` assuming all-to-all connectivity.

!!! warning "The initial state must be the ground state!"
    This transpiler stage assumes that the input state is ``|0\\rangle^{\\otimes N}``
    where ``N`` is the number of qubits. The stage should not be used on sub-circuits
    where the input state is not ``|0\\rangle^{\\otimes N}``.

This transpiler stage eliminates `Swap` gates by moving the gates preceding each `Swap`
gate.

# Examples
```jldoctest
julia> transpiler = RemoveSwapBySwappingGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count=2, gates=[hadamard(1), swap(1,2), sigma_x(2)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──H────☒───────
            |       
q[2]:───────☒────X──
                    



julia> transpiled_circuit = transpile(transpiler, circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──────────
               
q[2]:──H────X──
               



```
"""
function transpile(::RemoveSwapBySwappingGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit
    gates = get_circuit_gates(circuit)
    qubit_count = get_num_qubits(circuit)
    output_circuit = QuantumCircuit(qubit_count=qubit_count)
    qubit_mapping = Dict{Int,Int}()
    reverse_transpiled_gates = Vector{Gate}([])

    for gate in reverse(gates)
        if gate isa Snowflurry.Gate{Swap}
            update_qubit_mapping!(qubit_mapping, get_connected_qubits(gate))
        else
            moved_gate = move_gate(gate, qubit_mapping)
            push!(reverse_transpiled_gates, moved_gate)
        end
    end
    push!(output_circuit, reverse(reverse_transpiled_gates)...)
    return output_circuit
end

function update_qubit_mapping!(qubit_mapping::Dict{Int,Int}, connected_qubits::Vector{Int})
    outlet_qubit_1 = 0
    outlet_qubit_2 = 0

    if haskey(qubit_mapping, connected_qubits[1])
        outlet_qubit_2 = qubit_mapping[connected_qubits[1]]
        pop!(qubit_mapping, connected_qubits[1])
    else
        outlet_qubit_2 = connected_qubits[1]
    end

    if haskey(qubit_mapping, connected_qubits[2])
        outlet_qubit_1 = qubit_mapping[connected_qubits[2]]
        pop!(qubit_mapping, connected_qubits[2])
    else
        outlet_qubit_1 = connected_qubits[2]
    end

    qubit_mapping[connected_qubits[1]] = outlet_qubit_1
    qubit_mapping[connected_qubits[2]] = outlet_qubit_2
end

struct SimplifyTrivialGatesTranspiler<:Transpiler 
    atol::Real
end

SimplifyTrivialGatesTranspiler()=SimplifyTrivialGatesTranspiler(1e-6)

function is_trivial_gate(gate::Gate;atol=1e-6)::Bool

    symbol = get_gate_symbol(gate)
    
    params=get_gate_parameters(symbol)

    if symbol isa Identity
        return true
    elseif symbol isa Universal
        if isapprox( params["theta"],   0.;atol=atol) && 
            isapprox(params["phi"],     0.;atol=atol) &&
            isapprox(params["lambda"],  0.;atol=atol)
            return true
        end
    elseif symbol isa Rotation
        if isapprox( params["theta"],   0.;atol=atol) && 
            isapprox(params["phi"],     0.;atol=atol)
            return true
        end
    elseif symbol isa RotationX || symbol isa RotationY
        if isapprox(params["theta"],0.;atol=atol) 
            return true
        end
    elseif symbol isa PhaseShift
        if isapprox(params["lambda"],0.;atol=atol)
            return true
        end
    end
    
    return false
end

"""
    transpile(::SimplifyTrivialGatesTranspiler, circuit::QuantumCircuit)::QuantumCircuit

Implementation of the `SimplifyTrivialGatesTranspiler` transpiler stage 
which finds gates which have no effect on the state Ket, such as Identity, and 
parameterized gates with null parameters such as rotation_x(target, 0.).
The result of the input and output circuit on any 
arbitrary state Ket is unchanged (up to a global phase). The tolerance 
used for Base.isapprox() in each case can be set by passing an optional 
argument to the Transpiler, e.g:
transpiler=SimplifyTrivialGatesTranspiler(1.0e-10)

# Examples
```jldoctest
julia> transpiler=SimplifyTrivialGatesTranspiler();

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[identity_gate(1)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──I──
          
q[2]:─────
          
julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:      

julia> compare_circuits(circuit,transpiled_circuit)
true


julia> circuit = QuantumCircuit(qubit_count = 2, gates=[phase_shift(1,0.)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──Rz(0.0000)──
                   
q[2]:──────────────
                   

julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:      

julia> compare_circuits(circuit,transpiled_circuit)
true

julia> circuit = QuantumCircuit(qubit_count = 2, gates=[universal(1,0.,0.,0.)])
Quantum Circuit Object:
   qubit_count: 2 
q[1]:──U(θ=0.0000,ϕ=0.0000,λ=0.0000)──
                                      
q[2]:─────────────────────────────────
                                             
julia> transpiled_circuit=transpile(transpiler,circuit)
Quantum Circuit Object:
   qubit_count: 2 
q[1]:
     
q[2]:      

julia> compare_circuits(circuit,transpiled_circuit)
true

```
"""
function transpile(
    transpiler_stage::SimplifyTrivialGatesTranspiler, 
    circuit::QuantumCircuit)::QuantumCircuit

    qubit_count=get_num_qubits(circuit)
    output=QuantumCircuit(qubit_count=qubit_count)

    atol=transpiler_stage.atol

    for gate in get_circuit_gates(circuit)
        if ~is_trivial_gate(gate;atol=atol)
            push!(output, gate)
        end
    end

    return output
end

struct UnsupportedGatesTranspiler<:Transpiler end

function transpile(
    ::UnsupportedGatesTranspiler, 
    circuit::QuantumCircuit)::QuantumCircuit

    for gate in get_circuit_gates(circuit)
        if get_gate_symbol(gate) isa Controlled
            throw(NotImplementedError(:Transpiler,gate))
        end
    end

    return circuit
end
