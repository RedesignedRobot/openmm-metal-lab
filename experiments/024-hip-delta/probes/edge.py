import openmm as mm
def run(props):
    s = mm.System(); s.addParticle(1); s.addParticle(1)
    f = mm.HarmonicBondForce(); f.addBond(0, 1, 0.1, 100); s.addForce(f)
    nb = mm.NonbondedForce(); nb.addParticle(0.1, 0.3, 1); nb.addParticle(-0.1, 0.3, 1); nb.addException(0, 1, 0, 1, 0); s.addForce(nb)
    try:
        c = mm.Context(s, mm.VerletIntegrator(0.001), mm.Platform.getPlatform('Metal'), props)
        c.setPositions([mm.Vec3(0, 0, 0), mm.Vec3(0.2, 0, 0)])
        print(props, 'energy', c.getState(getEnergy=True).getPotentialEnergy())
    except Exception as e:
        print(props, 'exception', str(e).splitlines()[0][:160])
run({'Precision': 'single'})
run({'Precision': 'mixed'})
run({'Precision': 'double'})
run({'DeviceIndex': '0,0'})
