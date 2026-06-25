// Synthesizable UDP parser that extracts UDP payload from 64-bit AXI-Stream and realigns it.

`timescale 1ns / 1ps
`default_nettype none

module udp_parser (
    input  logic        clk,
    input  logic        rst_n,

    // AXI-Stream Input
    input  logic [63:0] s_axis_tdata,
    input  logic [7:0]  s_axis_tkeep,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    input  logic        s_axis_tuser,   // 0 = good packet, 1 = bad packet/FCS error
    output logic        s_axis_tready,

    // AXI-Stream Output
    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    // Parsed Metadata
    output logic [31:0] meta_src_ip,
    output logic [31:0] meta_dst_ip,
    output logic [15:0] meta_src_port,
    output logic [15:0] meta_dst_port,
    output logic [15:0] meta_udp_length,
    output logic        packet_valid
);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_ETH_IP_0,
        ST_ETH_IP_1,
        ST_IP_2,
        ST_IP_3,
        ST_IP_UDP_4,
        ST_PAYLOAD,
        ST_LAST_WORD
    } state_t;

    state_t state, next_state;

    logic [15:0] ether_type;
    logic [3:0]  ipv4_version;
    logic [3:0]  ipv4_ihl;
    logic [7:0]  ipv4_protocol;
    logic [31:0] ip_checksum_acc;
    logic [31:0] next_ip_checksum_acc;

    logic [31:0] r_src_ip;
    logic [31:0] r_dst_ip;
    logic [15:0] r_src_port;
    logic [15:0] r_dst_port;
    logic [15:0] r_udp_length;

    // Latch upper 6 bytes of Word 5 to realign payload to byte 0 in the next cycles
    logic [47:0] shift_reg_data;
    logic [5:0]  shift_reg_keep;
    logic        shift_reg_valid;

    logic        header_valid;
    logic        header_valid_reg;
    logic        packet_valid_pulse;

    logic        s_axis_tready_int;

    assign s_axis_tready_int = m_axis_tready || !m_axis_tvalid;
    assign s_axis_tready     = s_axis_tready_int;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (s_axis_tvalid && s_axis_tready_int) begin
            state <= next_state;
        end else if (state == ST_LAST_WORD && m_axis_tready) begin
            state <= ST_IDLE;
        end
    end

    always_comb begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (s_axis_tvalid) begin
                    next_state = ST_ETH_IP_0;
                end
            end
            ST_ETH_IP_0: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_ETH_IP_1;
            end
            ST_ETH_IP_1: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_IP_2;
            end
            ST_IP_2: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_IP_3;
            end
            ST_IP_3: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_IP_UDP_4;
            end
            ST_IP_UDP_4: begin
                if (s_axis_tlast) next_state = ST_IDLE;
                else              next_state = ST_PAYLOAD;
            end
            ST_PAYLOAD: begin
                if (s_axis_tlast) begin
                    // Check for residual payload bytes in upper 6 bytes of the last word
                    if (s_axis_tkeep[7:2] == 6'b0) begin
                        next_state = ST_IDLE;
                    end else begin
                        next_state = ST_LAST_WORD;
                    end
                end
            end
            ST_LAST_WORD: begin
                if (m_axis_tready) begin
                    next_state = ST_IDLE;
                end
            end
            default: next_state = ST_IDLE;
        endcase
    end

    // IPv4 header checksum calculation (folded one's complement)
    logic [19:0] sum_temp;
    logic [15:0] final_checksum;
    assign sum_temp = 20'(ip_checksum_acc[15:0]) + 20'(ip_checksum_acc[31:16]);
    assign final_checksum = ~(sum_temp[15:0] + 16'(sum_temp[19:16]));

    always_comb begin
        next_ip_checksum_acc = ip_checksum_acc;
        if (s_axis_tvalid && s_axis_tready_int) begin
            case (state)
                ST_IDLE: begin
                    next_ip_checksum_acc = 32'h0;
                end
                ST_ETH_IP_0: begin
                    // IPv4 DSCP/ECN, Ver, IHL
                    next_ip_checksum_acc = 32'({s_axis_tdata[55:48], s_axis_tdata[63:56]});
                end
                ST_ETH_IP_1: begin
                    // Length, Ident, Flags, Frag Offset, TTL, Protocol
                    next_ip_checksum_acc = ip_checksum_acc +
                                           32'({s_axis_tdata[7:0], s_axis_tdata[15:8]}) +
                                           32'({s_axis_tdata[23:16], s_axis_tdata[31:24]}) +
                                           32'({s_axis_tdata[39:32], s_axis_tdata[47:40]}) +
                                           32'({s_axis_tdata[55:48], s_axis_tdata[63:56]});
                end
                ST_IP_2: begin
                    // Checksum, Src IP, Dst IP [31:16]
                    next_ip_checksum_acc = ip_checksum_acc +
                                           32'({s_axis_tdata[7:0], s_axis_tdata[15:8]}) +
                                           32'({s_axis_tdata[23:16], s_axis_tdata[31:24]}) +
                                           32'({s_axis_tdata[39:32], s_axis_tdata[47:40]}) +
                                           32'({s_axis_tdata[55:48], s_axis_tdata[63:56]});
                end
                ST_IP_3: begin
                    // Dst IP [15:0]
                    next_ip_checksum_acc = ip_checksum_acc +
                                           32'({s_axis_tdata[7:0], s_axis_tdata[15:8]});
                end
                default: ;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ip_checksum_acc <= 32'h0;
        end else begin
            ip_checksum_acc <= next_ip_checksum_acc;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ether_type       <= 16'h0;
            ipv4_version     <= 4'h0;
            ipv4_ihl         <= 4'h0;
            ipv4_protocol    <= 8'h0;
            r_src_ip         <= 32'h0;
            r_dst_ip         <= 32'h0;
            r_src_port       <= 16'h0;
            r_dst_port       <= 16'h0;
            r_udp_length     <= 16'h0;
            header_valid_reg <= 1'b0;
            packet_valid_pulse <= 1'b0;
        end else begin
            packet_valid_pulse <= 1'b0;

            if (s_axis_tvalid && s_axis_tready_int) begin
                case (state)
                    ST_ETH_IP_0: begin
                        ether_type   <= {s_axis_tdata[39:32], s_axis_tdata[47:40]};
                        ipv4_version <= s_axis_tdata[55:52];
                        ipv4_ihl     <= s_axis_tdata[51:48];
                    end
                    ST_ETH_IP_1: begin
                        ipv4_protocol <= s_axis_tdata[63:56];
                    end
                    ST_IP_2: begin
                        r_src_ip[31:24] <= s_axis_tdata[23:16];
                        r_src_ip[23:16] <= s_axis_tdata[31:24];
                        r_src_ip[15:8]  <= s_axis_tdata[39:32];
                        r_src_ip[7:0]   <= s_axis_tdata[47:40];
                        r_dst_ip[31:24] <= s_axis_tdata[55:48];
                        r_dst_ip[23:16] <= s_axis_tdata[63:56];
                    end
                    ST_IP_3: begin
                        r_dst_ip[15:8]  <= s_axis_tdata[7:0];
                        r_dst_ip[7:0]   <= s_axis_tdata[15:8];
                        r_src_port      <= {s_axis_tdata[23:16], s_axis_tdata[31:24]};
                        r_dst_port      <= {s_axis_tdata[39:32], s_axis_tdata[47:40]};
                        r_udp_length    <= {s_axis_tdata[55:48], s_axis_tdata[63:56]};
                    end
                    ST_IP_UDP_4: begin
                        header_valid_reg <= (ether_type == 16'h0800) &&
                                            (ipv4_version == 4'h4) &&
                                            (ipv4_ihl == 4'h5) &&
                                            (ipv4_protocol == 8'h11) &&
                                            (final_checksum == 16'h0000) &&
                                            (s_axis_tuser == 1'b0);

                        packet_valid_pulse <= (ether_type == 16'h0800) &&
                                             (ipv4_version == 4'h4) &&
                                             (ipv4_ihl == 4'h5) &&
                                             (ipv4_protocol == 8'h11) &&
                                             (final_checksum == 16'h0000) &&
                                             (s_axis_tuser == 1'b0);
                    end
                    default: ;
                endcase
            end
        end
    end

    assign meta_src_ip     = r_src_ip;
    assign meta_dst_ip     = r_dst_ip;
    assign meta_src_port   = r_src_port;
    assign meta_dst_port   = r_dst_port;
    assign meta_udp_length = r_udp_length;
    assign packet_valid    = packet_valid_pulse;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg_data  <= 48'h0;
            shift_reg_keep  <= 6'h0;
            shift_reg_valid <= 1'b0;
        end else if (s_axis_tvalid && s_axis_tready_int) begin
            if (state == ST_IP_UDP_4) begin
                shift_reg_data  <= s_axis_tdata[63:16];
                shift_reg_keep  <= s_axis_tkeep[7:2];
                shift_reg_valid <= 1'b1;
            end else if (state == ST_PAYLOAD) begin
                shift_reg_data  <= s_axis_tdata[63:16];
                shift_reg_keep  <= s_axis_tkeep[7:2];
                shift_reg_valid <= 1'b1;
            end else begin
                shift_reg_valid <= 1'b0;
            end
        end else if (state == ST_LAST_WORD && m_axis_tready) begin
            shift_reg_valid <= 1'b0;
        end
    end

    always_comb begin
        m_axis_tdata  = 64'h0;
        m_axis_tkeep  = 8'h0;
        m_axis_tvalid = 1'b0;
        m_axis_tlast  = 1'b0;
        header_valid  = 1'b0;

        case (state)
            ST_PAYLOAD: begin
                if (shift_reg_valid) begin
                    m_axis_tdata  = {s_axis_tdata[15:0], shift_reg_data};
                    m_axis_tkeep  = {s_axis_tkeep[1:0], shift_reg_keep};
                    m_axis_tvalid = s_axis_tvalid && header_valid_reg;
                    if (s_axis_tlast && (s_axis_tkeep[7:2] == 6'b0)) begin
                        m_axis_tlast = 1'b1;
                    end
                end else if (s_axis_tvalid && s_axis_tlast) begin
                    // Corner case: payload ends in Word 5
                    m_axis_tdata  = {16'h0, s_axis_tdata[63:16]};
                    m_axis_tkeep  = {2'b0, s_axis_tkeep[7:2]};
                    header_valid  = (ether_type == 16'h0800) &&
                                    (ipv4_version == 4'h4) &&
                                    (ipv4_ihl == 4'h5) &&
                                    (ipv4_protocol == 8'h11) &&
                                    (final_checksum == 16'h0000) &&
                                    (s_axis_tuser == 1'b0);
                    m_axis_tvalid = header_valid;
                    m_axis_tlast  = 1'b1;
                end
            end
            ST_LAST_WORD: begin
                m_axis_tdata  = {16'h0, shift_reg_data};
                m_axis_tkeep  = {2'b0, shift_reg_keep};
                m_axis_tvalid = header_valid_reg;
                m_axis_tlast  = 1'b1;
            end
            default: ;
        endcase
    end

endmodule

`default_nettype wire
