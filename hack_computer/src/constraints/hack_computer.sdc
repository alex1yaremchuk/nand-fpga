# Primary board oscillator clock (27 MHz).
# Tang Primer 20K Dock routes this clock to top-level port "Clock".
create_clock -name clk27 -period 37.037 [get_ports {Clock}]
