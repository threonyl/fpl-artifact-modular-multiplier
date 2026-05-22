package modadd_pkg;

    function automatic int unsigned modadd_latency(
        bit REG_IN,
        bit REG_OUT,
        bit REG_ADD,
        bit CONC_ADDSUB
    );
        return int'(REG_IN) + int'(REG_ADD) + (int'(REG_ADD) & int'(!CONC_ADDSUB)) + int'(REG_OUT);
    endfunction

endpackage