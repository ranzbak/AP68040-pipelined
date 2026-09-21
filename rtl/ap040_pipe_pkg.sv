//--------------------------------------------------------------------------//
// AP040_PIPE - MC68040-style pipelined core                                //
//                                                                          //
// ap040_pipe_pkg.sv - types shared by the six stages (Minimig plan M1).    //
//                                                                          //
// Compile this file FIRST (it is a package).  The stage files import it.   //
//                                                                          //
// What travels down the pipe:                                              //
//   ID  -> EAC : id_t  (one decoded instruction; every extension word      //
//                       already gathered, both EAs normalised to ea_t)     //
//   EAC -> EAF : eac_t (id_t + the computed effective addresses and the    //
//                       pending address-register updates)                  //
//   EAF -> EX  : ex_t  (operands fetched; one entry per micro-op -- a      //
//                       sequenced instruction such as an exception entry   //
//                       sends several)                                     //
//   EX  -> WB  : wb_t  (results; WB commits them: registers, CCR/SR,       //
//                       control registers, the store)                      //
//                                                                          //
// Physical register numbers (5 bits): 0-7 D0-D7, 8-14 A0-A6, 15 = A7 as    //
// written in the instruction (resolved to USP/ISP/MSP in EAC from the      //
// architectural SR -- every instruction that changes S or M serialises and //
// redirects, so the SR seen in EAC is the one the instruction runs under), //
// 16 USP, 17 ISP, 18 MSP, 31 = none.                                       //
//--------------------------------------------------------------------------//

package ap040_pipe_pkg;

localparam [1:0] SZ_B = 2'd0, SZ_W = 2'd1, SZ_L = 2'd2;

localparam [4:0] R_A7L  = 5'd15;   // A7 before bank resolution
localparam [4:0] R_USP  = 5'd16;
localparam [4:0] R_ISP  = 5'd17;
localparam [4:0] R_MSP  = 5'd18;
localparam [4:0] R_NONE = 5'd31;

// effective-address kinds
localparam [2:0] EK_NONE = 3'd0,   // no operand
                 EK_DREG = 3'd1,   // Dn
                 EK_AREG = 3'd2,   // An
                 EK_IMM  = 3'd3,   // #<data> (value in bd)
                 EK_MEM  = 3'd4;   // memory: base + bd + index (+ memory indirect)

localparam [1:0] UPD_NONE = 2'd0, UPD_POST = 2'd1, UPD_PRE = 2'd2;
localparam [1:0] MI_NONE = 2'd0, MI_PRE = 2'd1, MI_POST = 2'd2;

// One effective address, all 68020+ modes normalised:
//   EA = (base_en ? reg : 0) + bd + (idx_en ? Xn.size*scale : 0)       (MI_NONE)
//   ptr = mem.L[(base) + bd + idx]  ; EA = ptr + od                     (MI_PRE)
//   ptr = mem.L[(base) + bd]        ; EA = ptr + idx + od               (MI_POST)
// PC-relative modes arrive with base_en = 0 and the extension word's
// address already folded into bd by ID.  (An)+/-(An) set upd; the step is
// the operand size (A7 byte = 2) and is applied in EAC.
typedef struct packed {
	logic [2:0]  kind;
	logic [4:0]  reg_n;     // Dn/An for DREG/AREG, base register for MEM
	logic        base_en;
	logic [1:0]  upd;
	logic [31:0] bd;        // displacement, absolute address or immediate
	logic        idx_en;
	logic [4:0]  idx_reg;
	logic        idx_l;     // index is Xn.L (else Xn.W sign-extended)
	logic [1:0]  scale;
	logic [1:0]  mi;
	logic [31:0] od;
	logic [2:0]  mode;      // the architectural mode/register fields, kept for
	logic [2:0]  mreg;      // legality checks and exception bookkeeping
} ea_t;

// instruction classes
typedef enum logic [5:0] {
	CL_NOP     = 6'd0,
	CL_ALU     = 6'd1,   // dst <- alu(src, dst); covers MOVE/MOVEA/MOVEQ/ADD/...
	CL_BCC     = 6'd2,   // Bcc/BRA (ID guessed taken)
	CL_BSR     = 6'd3,
	CL_DBCC    = 6'd4,
	CL_SCC     = 6'd5,
	CL_JMP     = 6'd6,
	CL_JSR     = 6'd7,
	CL_RTS     = 6'd8,
	CL_RTE     = 6'd9,
	CL_EXC     = 6'd10,  // decode-time exception (TRAP, illegal, A-line, F-line)
	CL_MOVE2SR = 6'd11,  // MOVE <ea>,SR
	CL_MOVEC   = 6'd12,
	CL_RESET   = 6'd13,  // internal: the reset vector fetch (ISP/PC)
	CL_INJECT  = 6'd14   // internal: an exception raised past EAF, re-entered
} cls_t;

typedef struct packed {
	logic [31:0] pc;
	logic [31:0] next_pc;      // address of the following instruction
	logic [15:0] opcode;
	logic [15:0] ext;          // first extension word (MOVEC selector, ...)
	logic [31:0] imm;          // branch displacement target / TRAP vector / MOVEC fields
	cls_t        cls;
	logic [5:0]  alu;
	logic [1:0]  size;
	logic [3:0]  cond;
	ea_t         src;
	ea_t         dst;
	logic        wr_ccr;       // result writes CCR (by the ALU's flag rule)
	logic        rmw;          // memory destination is read before it is written
	logic        priv;         // privileged: user mode -> vector 8
	logic        serialize;    // waits in EAF for EX/WB to drain
	logic [7:0]  exc_vec;      // CL_EXC: vector number
	logic        exc_next;     // CL_EXC: stacked PC is next_pc (TRAP) not pc
	logic [3:0]  exc_fmt;      // CL_EXC: frame format ($0, $2)
	logic [31:0] exc_addr;     // CL_EXC format $2: the address field
	logic [31:0] btarget;      // CL_BCC/BSR/DBCC: branch target
} id_t;

typedef struct packed {
	id_t         i;
	logic [31:0] src_ea;       // computed src address (or pointer address if MI)
	logic [31:0] src_add;      // MI: added to the fetched pointer
	logic [31:0] dst_ea;
	logic [31:0] dst_add;
	logic        u0_v;         // src (An)+/-(An) update
	logic [4:0]  u0_r;
	logic [31:0] u0_val;
	logic        u1_v;         // dst (An)+/-(An) update
	logic [4:0]  u1_r;
	logic [31:0] u1_val;
	logic [4:0]  src_r;        // resolved register numbers
	logic [4:0]  dst_r;
	logic        w0_v;         // the result register it will write (not known before EX)
	logic [4:0]  w0_r;
	logic        redirected;   // EA-calc already redirected IF to the JMP/JSR target
} eac_t;

// a data read: {valid, tag, byte address, size}.  Tags name what EA-fetch
// does with the answer.
localparam [2:0] T_SMI = 3'd0, T_DMI = 3'd1, T_SLD = 3'd2, T_DLD = 3'd3,
                 T_SEQ0 = 3'd4, T_SEQ1 = 3'd5, T_SEQ2 = 3'd6, T_VEC = 3'd7;
typedef struct packed { logic v; logic [2:0] t; logic [31:0] a; logic [1:0] sz; } rdreq_t;

// the first read an ordinary instruction needs (EA-calc issues it early, in
// the clock the instruction moves into EA-fetch, so the answer is there
// when EA-fetch looks for it)
function automatic rdreq_t first_rd(input id_t i, input logic [31:0] src_ea, input logic [31:0] dst_ea);
	rdreq_t r;
	logic ld_src, ld_dst;
	r = '0; r.sz = SZ_L;
	ld_src = (i.src.kind == EK_MEM) && !(i.cls == CL_JMP || i.cls == CL_JSR);
	ld_dst = (i.dst.kind == EK_MEM) && i.rmw;
	if (i.serialize) return r;
	if (i.src.kind == EK_MEM && i.src.mi != MI_NONE)      begin r.v = 1'b1; r.t = T_SMI; r.a = src_ea; end
	else if (i.dst.kind == EK_MEM && i.dst.mi != MI_NONE) begin r.v = 1'b1; r.t = T_DMI; r.a = dst_ea; end
	else if (ld_src) begin r.v = 1'b1; r.t = T_SLD; r.a = src_ea; r.sz = i.size; end
	else if (ld_dst) begin r.v = 1'b1; r.t = T_DLD; r.a = dst_ea; r.sz = i.size; end
	return r;
endfunction

// does an instruction store (for the read-after-write hazard of early reads)
function automatic logic stores(input id_t i);
	return (i.dst.kind == EK_MEM) || i.cls == CL_BSR || i.cls == CL_JSR || i.serialize;
endfunction

// what EX does with its result
localparam [2:0] DK_NONE = 3'd0, DK_REG = 3'd1, DK_MEM = 3'd2;

typedef struct packed {
	logic [31:0] pc;
	logic [31:0] next_pc;
	logic [15:0] opcode;
	cls_t        cls;
	logic [5:0]  alu;
	logic [1:0]  size;
	logic [3:0]  cond;
	logic [31:0] a;            // source operand (right-aligned)
	logic [31:0] b;            // destination operand (right-aligned)
	logic [2:0]  dk;           // destination kind
	logic [4:0]  dr;           // destination register
	logic [31:0] daddr;        // destination address (DK_MEM)
	logic        wr_ccr;
	logic        u0_v;  logic [4:0] u0_r;  logic [31:0] u0_val;
	logic        u1_v;  logic [4:0] u1_r;  logic [31:0] u1_val;
	logic [31:0] target;       // redirect target (JMP/JSR/RTS/RTE/exception vector)
	logic [31:0] btarget;      // taken-branch target
	logic        last;         // final micro-op of the instruction (retires)
	// sequenced micro-op fields (exception entry, RTE, reset)
	logic        st_v;         // store st_data (size st_size) at st_addr
	logic [31:0] st_addr;
	logic [31:0] st_data;
	logic [1:0]  st_size;
	logic        sp_v;         // write sp_val to physical stack pointer sp_r
	logic [4:0]  sp_r;
	logic [31:0] sp_val;
	logic        sr_v;         // write sr_val to SR
	logic [15:0] sr_val;
	logic        redirect;     // always redirect to target
	logic [3:0]  creg_sel;     // MOVEC
	logic        creg_to;      // MOVEC Rn,Rc
	logic        exc;          // exception-entry final micro-op (trace/X stream)
	logic        cc;           // Bcc/DBcc/Scc condition, evaluated in EA-fetch
} ex_t;

typedef struct packed {
	logic [31:0] pc;
	logic        last;
	logic        w0_v;  logic [4:0] w0_r;  logic [31:0] w0_val;
	logic        u0_v;  logic [4:0] u0_r;  logic [31:0] u0_val;
	logic        u1_v;  logic [4:0] u1_r;  logic [31:0] u1_val;
	logic        ccr_v; logic [4:0] ccr_val;
	logic        sr_v;  logic [15:0] sr_val;
	logic        st_v;  logic [31:0] st_addr; logic [31:0] st_data; logic [1:0] st_size;
	logic        creg_v; logic [3:0] creg_sel; logic [31:0] creg_val;
	logic        exc;   logic [31:0] exc_sp;
} wb_t;

// MOVEC compact selector codes (ext word bits 11:0 -> these)
localparam [3:0] CR_SFC = 4'd0, CR_DFC = 4'd1, CR_CACR = 4'd2, CR_VBR = 4'd3,
                 CR_USP = 4'd4, CR_ISP = 4'd5, CR_MSP = 4'd6, CR_BAD = 4'hF;

function automatic logic [31:0] sext8(input logic [7:0] v);  return {{24{v[7]}}, v}; endfunction
function automatic logic [31:0] sext16(input logic [15:0] v); return {{16{v[15]}}, v}; endfunction

function automatic logic [31:0] szmask(input logic [1:0] sz);
	return (sz == SZ_B) ? 32'h0000_00FF : (sz == SZ_W) ? 32'h0000_FFFF : 32'hFFFF_FFFF;
endfunction

// 68000 condition codes over CCR {X,N,Z,V,C}
function automatic logic cond_true(input logic [3:0] c, input logic [4:0] ccr);
	logic n, z, v, cy;
	n = ccr[3]; z = ccr[2]; v = ccr[1]; cy = ccr[0];
	case (c)
		4'h0: return 1'b1;            4'h1: return 1'b0;
		4'h2: return !cy && !z;       4'h3: return cy || z;
		4'h4: return !cy;             4'h5: return cy;
		4'h6: return !z;              4'h7: return z;
		4'h8: return !v;              4'h9: return v;
		4'hA: return !n;              4'hB: return n;
		4'hC: return n == v;          4'hD: return n != v;
		4'hE: return !z && (n == v);  default: return z || (n != v);
	endcase
endfunction

// A7 in the instruction -> the stack pointer the SR selects
function automatic logic [4:0] resolve_sp(input logic [4:0] r, input logic s, input logic m);
	if (r != R_A7L) return r;
	return !s ? R_USP : (m ? R_MSP : R_ISP);
endfunction

endpackage
