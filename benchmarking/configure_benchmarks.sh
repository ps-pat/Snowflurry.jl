#!/bin/bash
# This script configures the Julia Project to use the 
# Snowflake Package located in the current path (pwd), 
# in development mode, in order to run the benchmarks on it.
julia --project=benchmarking -e 'using Pkg;
          Pkg.develop(PackageSpec(path=pwd())); 
          Pkg.instantiate();'