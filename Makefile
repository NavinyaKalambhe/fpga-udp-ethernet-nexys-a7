# Simulation for the UDP/Ethernet node (Icarus Verilog + Python 3, no other dependencies)
.SILENT:
IVERILOG ?= iverilog
VVP      ?= vvp
RTL := rtl/frame_ram.v rtl/rmii_rx.v rtl/rmii_tx.v rtl/net_engine.v rtl/eth_udp.v \
       rtl/font_rom.v rtl/status_writer.v rtl/vga_text.v rtl/eth_node.v

.PHONY: test vectors display dump clean
test: vectors
	mkdir -p build
	$(IVERILOG) -g2005 -o build/tb_eth $(RTL) tb/tb_eth.v
	$(VVP) build/tb_eth +vec=tb/vectors/vectors.txt | tee build/results.txt | grep -E "PASS|FAIL|ALL"
	! grep -qE "^FAIL|TEST\(S\) FAILED" build/results.txt

vectors:
	python3 scripts/make_vectors.py > /dev/null

display:                      # regenerate font_rom.v and status_writer.v from scripts/gen_display.py
	python3 scripts/gen_display.py > /dev/null

dump: vectors                 # simulate and write the VGA dashboard to docs/vga_dashboard_sim.png
	mkdir -p build
	$(IVERILOG) -g2005 -o build/tb_eth $(RTL) tb/tb_eth.v
	$(VVP) build/tb_eth +vec=tb/vectors/vectors.txt +dump > /dev/null
	python3 scripts/frame2png.py frame frame.txt docs/vga_dashboard_sim.png

clean:
	rm -rf build frame.txt
