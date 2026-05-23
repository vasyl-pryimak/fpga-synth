VERILATOR = verilator
VSRCS     = ../reverb_core.v ../delay_line.v
OBJ_DIR   = obj_dir

.PHONY: all clean

all: sim

sim: $(VSRCS) sim_main.cpp
	$(VERILATOR) --cc --exe --build -j 0 \
		-Wall --Wno-fatal \
		-CFLAGS "-O2 -std=c++17" \
		-Mdir $(OBJ_DIR) \
		-o ../reverb-sim \
		$(VSRCS) sim_main.cpp

clean:
	rm -rf $(OBJ_DIR) ../reverb-sim
