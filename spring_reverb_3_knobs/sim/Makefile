VERILATOR = verilator
VERILATOR_FLAGS = --cc --exe --build -j 0 -Wall --Wno-fatal -CFLAGS "-O2 -std=c++17" -I.. -Mdir obj_dir -o ../reverb-sim

all: sim

sim: sim_top.v ../reverb_core.v ../pitch_shifter.v sim_main.cpp
	$(VERILATOR) $(VERILATOR_FLAGS) sim_top.v sim_main.cpp

clean:
	rm -rf obj_dir ../reverb-sim
