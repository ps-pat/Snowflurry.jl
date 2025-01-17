using Snowflurry

circuit = QuantumCircuit(qubit_count=2, gates=[
    hadamard(1),
    control_x(1, 2),
])

user = ENV["ANYON_QUANTUM_USER"]
token = ENV["ANYON_QUANTUM_TOKEN"]
host = ENV["ANYON_QUANTUM_HOST"]

qpu = AnyonYukonQPU(host=host, user=user, access_token=token)

shot_count = 200
task = Task(() -> run_job(qpu, circuit, shot_count))
schedule(task)

yieldto(task)

# Simulate work by calculating the nth Fibonacci number slowly
function fibonacci(n)
  if n <= 2
    return 1
  end
  return fibonacci(n - 1) + fibonacci(n - 2)
end

fibonacci(30)

result = fetch(task)
println(result)
