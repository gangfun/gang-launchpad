# GangSwap math model (docs/SPEC-GANGSWAP-2026-11-22.md §7.4). Run: python3 test/proto/gangswap_sim.py
import random
T=1_000_000_000.0
def run(G,steps=40,vol=0,seed=1,fee=0.01):
    X=200e6; Q=G; V=G*X/T; R=Q-V    # real seeded, virtual V, boost reserve = V
    boost=V; supply=T; out_tokens=800e6; feeq=0; burned=0
    eff=lambda: R+V
    def buy(q):  # quote in, fee on input to collector
        nonlocal X,R,feeq,out_tokens
        f=q*fee; qi=q-f; dx=X*qi/(eff()+qi); X-=dx; R+=qi; feeq+=f; return dx
    def sell(dx): # tokens in, fee on input burned
        nonlocal X,R,supply,burned
        f=dx*fee; di=dx-f; supply-=f; burned+=f
        dq=eff()*di/(X+di); dq=min(dq,R); X+=di; R-=dq; return dq
    rnd=random.Random(seed)
    for i in range(steps):           # boost: pays the 1% fee like any buy (spec Q2), bought tokens to 0xdead
        b=V/steps; f=b*fee; bi=b-f; dx=X*bi/(eff()+bi); X-=dx; R+=bi; feeq+=f; supply-=dx; burned+=dx
        if vol:
            q=rnd.uniform(0,vol*G); 
            if rnd.random()<0.5: out_tokens+=buy(q)
            else:
                dx=min(out_tokens, q/(eff()/X)); out_tokens-=dx; sell(dx)
    for _ in range(vol*50 if vol else 0):
        q=rnd.uniform(0,0.05*G)
        if rnd.random()<0.5: out_tokens+=buy(q)
        else:
            dx=min(out_tokens,q/(eff()/X)); out_tokens-=dx; sell(dx)
    got=sell(out_tokens) # everyone outside sells all
    return dict(G=G,V=V,R_left=R,feeq=feeq,burned=burned/1e6,supply=supply/1e6,last_sell=got)
for G in (6,9,12,15):
    print({k:round(v,4) for k,v in run(G).items()})
print('with random trading noise (illustrative only: a crude random walk of buys and sells, not a market model)')
for G in (6,9,15):
    print({k:round(v,4) for k,v in run(G,vol=1).items()})
# compare V2 baseline residue
for G in (6,9,12,15): print('V2 residue',G, round(G*200e6/T,3))
