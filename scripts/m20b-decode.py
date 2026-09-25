#!/usr/bin/env python3
"""Generate rtl/na1/na1_m37702_decode.sv from a table that mirrors MAME 0.289
m37710op.h TABLE_OPCODES (base), TABLE_OPCODES2 ($42 prefix, B accumulator)
and TABLE_OPCODES3 ($89 prefix, MPY/DIV/XAB/RLA/LDT) entry by entry, and the
CLK_* cycle accounting of m37710cm.h / the OP_* macros.

Output fields (packed, see the generated file): class, addressing mode, width
source, sub-operation, B-accumulator flag, static MAME cycle cost for 8-bit
and for 16-bit operation width. Dynamic costs (direct-page +1, page crossing,
taken branch, PSH/PUL register lists, MVN/MVP, RLA, DIV non-zero) are added by
the core. Run: python scripts/m20b-decode.py
"""
import os

# ---- enumerations shared with the RTL (keep in sync with na1_m37702_pkg)
CLS = ['ALU','STA','LDX','STX','CPX','RMW','RMWA','INCX','SEB','BBS','LDM','BCC','JMP',
       'PUSH','PULL','PSH','PUL','FLAG','TRANS','XAB','NOP','WAI','STP','BRK','MVN','MPY',
       'DIV','RLA','LDT','UNIMP','PFB','PFXM']
MODE = ['NONE','IMM','D','A','AL','DX','DY','AX','AY','ALX','DI','DLI','DXI','DIY','DLIY','S','SIY']
WSRC = {'M':0,'X':1,'8':2,'16':3}
# MAME CLK_<mode> (read) and CLK_W_<mode> (write / RMW)
CLK_R = dict(IMM=0,D=1,A=2,AL=3,DX=2,DY=2,AX=2,AY=2,ALX=3,DI=3,DLI=4,DXI=4,DIY=3,DLIY=4,S=2,SIY=5,NONE=0)
CLK_W = dict(CLK_R); CLK_W.update(AX=3, AY=3)
ALU_SUB = dict(ORA=0,AND=1,EOR=2,ADC=3,LDA=4,CMP=5,SBC=6)
RMW_SUB = dict(ASL=0,ROL=1,LSR=2,ROR=3,INC=4,DEC=5)
COND = dict(PL=0,MI=1,VC=2,VS=3,CC=4,CS=5,NE=6,EQ=7)
FLAG_SUB = dict(CLC=0,SEC=1,CLI=2,SEI=3,CLV=4,CLM=5,SEM=6,REP=7,SEP=8)
TRANS_SUB = dict(TAX=0,TAY=1,TXA=2,TYA=3,TSX=4,TXS=5,TXY=6,TYX=7,TAS=8,TSA=9,TAD=10,TDA=11)
JMP_SUB = dict(JMP_A=0,JMP_AI=1,JMP_AXI=2,JMP_AL=3,JML_AI=4,JSR_A=5,JSR_AXI=6,JSL=7,RTS=8,RTL=9,RTI=10)
PUSH_SUB = dict(PHA=0,PHX=1,PHY=2,PHP=3,PHD=4,PHT=5,PHK=6,PEA=7,PEI=8,PER=9)
PULL_SUB = dict(PLA=0,PLX=1,PLY=2,PLP=3,PLD=4,PLT=5)
JMP_COST = dict(JMP_A=3,JMP_AI=5,JMP_AXI=5,JMP_AL=4,JML_AI=6,JSR_A=5,JSR_AXI=7,JSL=8,RTS=6,RTL=6,RTI=8)
PUSH_COST = dict(PHP=3,PHD=4,PHT=3,PHK=3,PEA=5,PEI=6,PER=6)   # PHA/PHX/PHY: width dependent
PULL_COST = dict(PLP=4,PLD=5,PLT=4)                          # PLA/PLX/PLY: width dependent

def E(cls, mode='NONE', w='M', sub=0, useb=0, c8=None, c16=None):
    return dict(cls=cls, mode=mode, w=w, sub=sub, useb=useb, c8=c8, c16=c16)

def alu(name, mode, useb=0):  return E('ALU', mode, 'M', ALU_SUB[name], useb)
def sta(mode, useb=0):        return E('STA', mode, 'M', 0, useb)
def ldx(reg, mode):           return E('LDX', mode, 'X', reg)
def stx(reg, mode):           return E('STX', mode, 'X', reg)
def cpx(reg, mode):           return E('CPX', mode, 'X', reg)
def rmw(name, mode):          return E('RMW', mode, 'M', RMW_SUB[name])
def rmwa(name, useb=0):       return E('RMWA', 'NONE', 'M', RMW_SUB[name], useb)
def incx(reg, dec):           return E('INCX', 'NONE', 'X', reg | (dec << 1))
def bcc(cond):                return E('BCC', 'NONE', '8', COND[cond])
def jmp(name):                return E('JMP', 'NONE', '8', JMP_SUB[name])
def push(name, useb=0):       return E('PUSH', 'DI' if name == 'PEI' else 'NONE', 'M' if name == 'PHA' else ('X' if name in ('PHX','PHY') else '8'), PUSH_SUB[name], useb)
def pull(name, useb=0):       return E('PULL', 'NONE', 'M' if name == 'PLA' else ('X' if name in ('PLX','PLY') else '8'), PULL_SUB[name], useb)
def flag(name):               return E('FLAG', 'NONE', '8', FLAG_SUB[name])
def trans(name, useb=0):      return E('TRANS', 'NONE', '8', TRANS_SUB[name], useb)

# ---- TABLE_OPCODES (MAME m37710op.h), one entry per opcode $00-$FF
base = {
 0x00:E('BRK'), 0x01:alu('ORA','DXI'), 0x02:E('NOP'), 0x03:alu('ORA','S'), 0x04:E('SEB','D',sub=0), 0x05:alu('ORA','D'),
 0x06:rmw('ASL','D'), 0x07:alu('ORA','DLI'), 0x08:push('PHP'), 0x09:alu('ORA','IMM'), 0x0a:rmwa('ASL'), 0x0b:push('PHD'),
 0x0c:E('SEB','A',sub=0), 0x0d:alu('ORA','A'), 0x0e:rmw('ASL','A'), 0x0f:alu('ORA','AL'),
 0x10:bcc('PL'), 0x11:alu('ORA','DIY'), 0x12:alu('ORA','DI'), 0x13:alu('ORA','SIY'), 0x14:E('SEB','D',sub=1), 0x15:alu('ORA','DX'),
 0x16:rmw('ASL','DX'), 0x17:alu('ORA','DLIY'), 0x18:flag('CLC'), 0x19:alu('ORA','AY'), 0x1a:rmwa('DEC'), 0x1b:trans('TAS'),
 0x1c:E('SEB','A',sub=1), 0x1d:alu('ORA','AX'), 0x1e:rmw('ASL','AX'), 0x1f:alu('ORA','ALX'),
 0x20:jmp('JSR_A'), 0x21:alu('AND','DXI'), 0x22:jmp('JSL'), 0x23:alu('AND','S'), 0x24:E('BBS','D',sub=0), 0x25:alu('AND','D'),
 0x26:rmw('ROL','D'), 0x27:alu('AND','DLI'), 0x28:pull('PLP'), 0x29:alu('AND','IMM'), 0x2a:rmwa('ROL'), 0x2b:pull('PLD'),
 0x2c:E('BBS','A',sub=0), 0x2d:alu('AND','A'), 0x2e:rmw('ROL','A'), 0x2f:alu('AND','AL'),
 0x30:bcc('MI'), 0x31:alu('AND','DIY'), 0x32:alu('AND','DI'), 0x33:alu('AND','SIY'), 0x34:E('BBS','D',sub=1), 0x35:alu('AND','DX'),
 0x36:rmw('ROL','DX'), 0x37:alu('AND','DLIY'), 0x38:flag('SEC'), 0x39:alu('AND','AY'), 0x3a:rmwa('INC'), 0x3b:trans('TSA'),
 0x3c:E('BBS','A',sub=1), 0x3d:alu('AND','AX'), 0x3e:rmw('ROL','AX'), 0x3f:alu('AND','ALX'),
 0x40:jmp('RTI'), 0x41:alu('EOR','DXI'), 0x42:E('PFB'), 0x43:alu('EOR','S'), 0x44:E('MVN',sub=1), 0x45:alu('EOR','D'),
 0x46:rmw('LSR','D'), 0x47:alu('EOR','DLI'), 0x48:push('PHA'), 0x49:alu('EOR','IMM'), 0x4a:rmwa('LSR'), 0x4b:push('PHK'),
 0x4c:jmp('JMP_A'), 0x4d:alu('EOR','A'), 0x4e:rmw('LSR','A'), 0x4f:alu('EOR','AL'),
 0x50:bcc('VC'), 0x51:alu('EOR','DIY'), 0x52:alu('EOR','DI'), 0x53:alu('EOR','SIY'), 0x54:E('MVN',sub=0), 0x55:alu('EOR','DX'),
 0x56:rmw('LSR','DX'), 0x57:alu('EOR','DLIY'), 0x58:flag('CLI'), 0x59:alu('EOR','AY'), 0x5a:push('PHY'), 0x5b:trans('TAD'),
 0x5c:jmp('JMP_AL'), 0x5d:alu('EOR','AX'), 0x5e:rmw('LSR','AX'), 0x5f:alu('EOR','ALX'),
 0x60:jmp('RTS'), 0x61:alu('ADC','DXI'), 0x62:push('PER'), 0x63:alu('ADC','S'), 0x64:E('LDM','D'), 0x65:alu('ADC','D'),
 0x66:rmw('ROR','D'), 0x67:alu('ADC','DLI'), 0x68:pull('PLA'), 0x69:alu('ADC','IMM'), 0x6a:rmwa('ROR'), 0x6b:jmp('RTL'),
 0x6c:jmp('JMP_AI'), 0x6d:alu('ADC','A'), 0x6e:rmw('ROR','A'), 0x6f:alu('ADC','AL'),
 0x70:bcc('VS'), 0x71:alu('ADC','DIY'), 0x72:alu('ADC','DI'), 0x73:alu('ADC','SIY'), 0x74:E('LDM','DX'), 0x75:alu('ADC','DX'),
 0x76:rmw('ROR','DX'), 0x77:alu('ADC','DLIY'), 0x78:flag('SEI'), 0x79:alu('ADC','AY'), 0x7a:pull('PLY'), 0x7b:trans('TDA'),
 0x7c:jmp('JMP_AXI'), 0x7d:alu('ADC','AX'), 0x7e:rmw('ROR','AX'), 0x7f:alu('ADC','ALX'),
 0x80:E('BCC','NONE','8',8), 0x81:sta('DXI'), 0x82:E('BCC','NONE','8',9), 0x83:sta('S'), 0x84:stx(1,'D'), 0x85:sta('D'),
 0x86:stx(0,'D'), 0x87:sta('DLI'), 0x88:incx(1,1), 0x89:E('PFXM'), 0x8a:trans('TXA'), 0x8b:push('PHT'),
 0x8c:stx(1,'A'), 0x8d:sta('A'), 0x8e:stx(0,'A'), 0x8f:sta('AL'),
 0x90:bcc('CC'), 0x91:sta('DIY'), 0x92:sta('DI'), 0x93:sta('SIY'), 0x94:stx(1,'DX'), 0x95:sta('DX'),
 0x96:stx(0,'DY'), 0x97:sta('DLIY'), 0x98:trans('TYA'), 0x99:sta('AY'), 0x9a:trans('TXS'), 0x9b:trans('TXY'),
 0x9c:E('LDM','A'), 0x9d:sta('AX'), 0x9e:E('LDM','AX'), 0x9f:sta('ALX'),
 0xa0:ldx(1,'IMM'), 0xa1:alu('LDA','DXI'), 0xa2:ldx(0,'IMM'), 0xa3:alu('LDA','S'), 0xa4:ldx(1,'D'), 0xa5:alu('LDA','D'),
 0xa6:ldx(0,'D'), 0xa7:alu('LDA','DLI'), 0xa8:trans('TAY'), 0xa9:alu('LDA','IMM'), 0xaa:trans('TAX'), 0xab:pull('PLT'),
 0xac:ldx(1,'A'), 0xad:alu('LDA','A'), 0xae:ldx(0,'A'), 0xaf:alu('LDA','AL'),
 0xb0:bcc('CS'), 0xb1:alu('LDA','DIY'), 0xb2:alu('LDA','DI'), 0xb3:alu('LDA','SIY'), 0xb4:ldx(1,'DX'), 0xb5:alu('LDA','DX'),
 0xb6:ldx(0,'DY'), 0xb7:alu('LDA','DLIY'), 0xb8:flag('CLV'), 0xb9:alu('LDA','AY'), 0xba:trans('TSX'), 0xbb:trans('TYX'),
 0xbc:ldx(1,'AX'), 0xbd:alu('LDA','AX'), 0xbe:ldx(0,'AY'), 0xbf:alu('LDA','ALX'),
 0xc0:cpx(1,'IMM'), 0xc1:alu('CMP','DXI'), 0xc2:flag('REP'), 0xc3:alu('CMP','S'), 0xc4:cpx(1,'D'), 0xc5:alu('CMP','D'),
 0xc6:rmw('DEC','D'), 0xc7:alu('CMP','DLI'), 0xc8:incx(1,0), 0xc9:alu('CMP','IMM'), 0xca:incx(0,1), 0xcb:E('WAI'),
 0xcc:cpx(1,'A'), 0xcd:alu('CMP','A'), 0xce:rmw('DEC','A'), 0xcf:alu('CMP','AL'),
 0xd0:bcc('NE'), 0xd1:alu('CMP','DIY'), 0xd2:alu('CMP','DI'), 0xd3:alu('CMP','SIY'), 0xd4:push('PEI'), 0xd5:alu('CMP','DX'),
 0xd6:rmw('DEC','DX'), 0xd7:alu('CMP','DLIY'), 0xd8:flag('CLM'), 0xd9:alu('CMP','AY'), 0xda:push('PHX'), 0xdb:E('STP'),
 0xdc:jmp('JML_AI'), 0xdd:alu('CMP','AX'), 0xde:rmw('DEC','AX'), 0xdf:alu('CMP','ALX'),
 0xe0:cpx(0,'IMM'), 0xe1:alu('SBC','DXI'), 0xe2:flag('SEP'), 0xe3:alu('SBC','S'), 0xe4:cpx(0,'D'), 0xe5:alu('SBC','D'),
 0xe6:rmw('INC','D'), 0xe7:alu('SBC','DLI'), 0xe8:incx(0,0), 0xe9:alu('SBC','IMM'), 0xea:E('NOP'), 0xeb:E('PSH'),
 0xec:cpx(0,'A'), 0xed:alu('SBC','A'), 0xee:rmw('INC','A'), 0xef:alu('SBC','AL'),
 0xf0:bcc('EQ'), 0xf1:alu('SBC','DIY'), 0xf2:alu('SBC','DI'), 0xf3:alu('SBC','SIY'), 0xf4:push('PEA'), 0xf5:alu('SBC','DX'),
 0xf6:rmw('INC','DX'), 0xf7:alu('SBC','DLIY'), 0xf8:flag('SEM'), 0xf9:alu('SBC','AY'), 0xfa:pull('PLX'), 0xfb:E('PUL'),
 0xfc:jmp('JSR_AXI'), 0xfd:alu('SBC','AX'), 0xfe:rmw('INC','AX'), 0xff:alu('SBC','ALX'),
}
assert len(base) == 256

# ---- TABLE_OPCODES2 ($42 prefix): B-accumulator forms; everything else UNIMP
GMODES = {0x1:'DXI',0x3:'S',0x5:'D',0x7:'DLI',0x9:'IMM',0xd:'A',0xf:'AL',0x11:'DIY',0x12:'DI',0x13:'SIY',0x15:'DX',0x17:'DLIY',0x19:'AY',0x1d:'AX',0x1f:'ALX'}
pfb = {}
for hi, name in ((0x00,'ORA'),(0x20,'AND'),(0x40,'EOR'),(0x60,'ADC'),(0xa0,'LDA'),(0xc0,'CMP'),(0xe0,'SBC')):
    for lo, mode in GMODES.items():
        pfb[hi | lo] = alu(name, mode, useb=1)
for lo, mode in GMODES.items():
    if lo != 0x9:  # no STB #imm
        pfb[0x80 | lo] = sta(mode, useb=1)
pfb.update({0x0a:rmwa('ASL',1), 0x1a:rmwa('DEC',1), 0x1b:trans('TAS',1), 0x2a:rmwa('ROL',1), 0x3a:rmwa('INC',1), 0x3b:trans('TSA',1),
            0x48:push('PHA',1), 0x4a:rmwa('LSR',1), 0x5b:trans('TAD',1), 0x68:pull('PLA',1), 0x6a:rmwa('ROR',1), 0x7b:trans('TDA',1),
            0x8a:trans('TXA',1), 0x98:trans('TYA',1), 0xa8:trans('TAY',1), 0xaa:trans('TAX',1)})
# ---- TABLE_OPCODES3 ($89 prefix)
pfxm = {}
for lo, mode in GMODES.items():
    pfxm[0x00 | lo] = E('MPY', mode, 'M')
    pfxm[0x20 | lo] = E('DIV', mode, 'M')
pfxm.update({0x28:E('XAB'), 0x49:E('RLA','IMM','M'), 0xc2:E('LDT','IMM','8')})

def costs(e):
    """Static MAME cycles for 8-bit and 16-bit operation width (None -> 0)."""
    c, m = e['cls'], e['mode']
    if c in ('ALU','LDX','CPX'):  return 1+1+CLK_R[m], 1+2+CLK_R[m]
    if c in ('STA','STX'):        return 1+1+CLK_W[m], 1+2+CLK_W[m]
    if c in ('RMW','SEB'):        return 1+3+CLK_W[m], 1+5+CLK_W[m]
    if c in ('LDM','BBS'):        return 1+1+CLK_R[m], 1+2+CLK_R[m]
    if c == 'MPY':                return 1+1+CLK_R[m]+14, 1+2+CLK_R[m]+22
    if c == 'DIV':                return 1+1+CLK_R[m]+17, 1+2+CLK_R[m]+17
    if c in ('RMWA','INCX','TRANS','NOP'): return 2, 2
    if c == 'FLAG':               return (3, 3) if e['sub'] >= 5 else (2, 2)
    if c == 'BCC':                return (3, 3) if e['sub'] == 8 else ((4, 4) if e['sub'] == 9 else (2, 2))
    if c == 'JMP':                v = JMP_COST[[k for k, s in JMP_SUB.items() if s == e['sub']][0]]; return v, v
    if c == 'PUSH':
        nm = [k for k, s in PUSH_SUB.items() if s == e['sub']][0]
        if nm in ('PHA','PHX','PHY'): return 3, 4
        return PUSH_COST[nm], PUSH_COST[nm]
    if c == 'PULL':
        nm = [k for k, s in PULL_SUB.items() if s == e['sub']][0]
        if nm in ('PLA','PLX','PLY'): return 4, 5
        return PULL_COST[nm], PULL_COST[nm]
    if c == 'PSH':                return 12, 12
    if c == 'PUL':                return 14, 14
    if c == 'XAB':                return 6, 6
    if c == 'MVN':                return 7, 7
    if c == 'BRK':                return 2, 2      # + 13 by the software interrupt
    if c == 'LDT':                return 2, 2
    if c == 'RLA':                return 0, 0      # 6 per rotate, dynamic
    if c in ('WAI','STP','UNIMP','PFXM'): return 0, 0
    if c == 'PFB':                return 2, 2
    raise KeyError(c)

def packed(e, c8, c16):
    # dec_t packed layout (MSB first): cls[5:0] mode[4:0] wsrc[1:0] sub[3:0] useb c8[5:0] c16[5:0] = 30 bits.
    # Emitted as a plain constant: Quartus 17.0 (Verific) hits an internal error
    # ("Can't extract a ROM based on this value") on a case of struct literals.
    v = CLS.index(e['cls'])
    v = (v << 5) | MODE.index(e['mode'])
    v = (v << 2) | WSRC[e['w']]
    v = (v << 4) | e['sub']
    v = (v << 1) | e['useb']
    v = (v << 6) | c8
    v = (v << 6) | c16
    return v

def emit(fh, tbl, pfx):
    for op in range(256):
        e = tbl.get(op, E('UNIMP'))
        c8, c16 = costs(e)
        fh.write("    10'h%x%02x: d = 30'h%08x; // %s %s w%d sub%d%s c%d/%d\n" %
                 (pfx, op, packed(e, c8, c16), 'C_'+e['cls'], 'M_'+e['mode'], WSRC[e['w']], e['sub'],
                  ' B' if e['useb'] else '', c8, c16))

def main():
    out = os.path.join(os.path.dirname(__file__), '..', 'rtl', 'na1', 'na1_m37702_decode.sv')
    with open(out, 'w', newline='\n') as fh:
        fh.write("// GENERATED by scripts/m20b-decode.py from the MAME 0.289 m37710op.h opcode\n"
                 "// tables (TABLE_OPCODES / $42 B-accumulator prefix / $89 MPY-DIV prefix) and\n"
                 "// CLK_* accounting. Do not edit by hand.\n"
                 "package na1_m37702_pkg;\n"
                 "  typedef enum logic [5:0] {%s} cls_e;\n" % ', '.join('C_'+c for c in CLS) +
                 "  typedef enum logic [4:0] {%s} mode_e;\n" % ', '.join('M_'+m for m in MODE) +
                 "  typedef struct packed { cls_e cls; mode_e mode; logic [1:0] wsrc; logic [3:0] sub; logic useb; logic [5:0] c8; logic [5:0] c16; } dec_t;\n"
                 "  // wsrc: 0 = M flag selects width, 1 = X flag, 2 = always 8, 3 = always 16\n"
                 "  // packed constant per entry: {cls, mode, wsrc, sub, useb, c8, c16}\n"
                 "  function automatic dec_t decode(input logic [1:0] pfx, input logic [7:0] op);\n"
                 "    logic [29:0] d;\n    case ({pfx, op})\n")
        emit(fh, base, 0); emit(fh, pfb, 1); emit(fh, pfxm, 2)
        fh.write("    default: d = 30'h%08x; // C_UNIMP M_NONE w2\n" % packed(E('UNIMP', w='8'), 0, 0) +
                 "    endcase\n    return dec_t'(d);\n  endfunction\nendpackage\n")
    print('wrote', out)

if __name__ == '__main__':
    main()
