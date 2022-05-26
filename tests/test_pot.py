# HQ XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
# HQ X
# HQ X   quippy: Python interface to QUIP atomistic simulation library
# HQ X
# HQ X   Copyright James Kermode 2019
# HQ X
# HQ X   These portions of the source code are released under the GNU General
# HQ X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
# HQ X
# HQ X   If you would like to license the source code under different terms,
# HQ X   please contact James Kermode, james.kermode@gmail.com
# HQ X
# HQ X   When using this software, please cite the following reference:
# HQ X
# HQ X   http://www.jrkermode.co.uk/quippy
# HQ X
# HQ XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

#from quippy.system_module import verbosity_push
#verbosity_push(1)

""" Si structure to be studied was generated with the old vesion:
$bash: python2
> import quippy
> quippy.system_reseed_rng(2065775975)
> at = quippy.diamond(5.44, 14)
> quippy.randomise(at.pos, 0.1)
> print(at.positions)
[[-0.04999922  0.01792964  0.01711494]
 [ 1.32315378  1.40346929  1.31076982]
 [ 2.74556053  2.70835021 -0.01165843]
 [ 4.07586501  4.08194164  1.31668422]
 [ 2.72327672  0.03309653  2.7117486 ]
 [ 4.05189592  1.31345721  4.09867727]
 [-0.04529554  2.67534616  2.72889766]
 [ 1.37788647  4.08297002  4.12304365]]
"""

import unittest
import quippy
import numpy as np
import quippytest
import ase.build
from ase.atoms import Atoms
from ase.calculators.emt import EMT
from quippy.potential import Potential

diamond_pos = np.array([[-0.04999922, 0.01792964, 0.01711494],
                        [1.32315378, 1.40346929, 1.31076982],
                        [2.74556053, 2.70835021, -0.01165843],
                        [4.07586501, 4.08194164, 1.31668422],
                        [2.72327672, 0.03309653, 2.7117486],
                        [4.05189592, 1.31345721, 4.09867727],
                        [-0.04529554, 2.67534616, 2.72889766],
                        [1.37788647, 4.08297002, 4.12304365]])


class TestCalculator_SW_Potential(quippytest.QuippyTestCase):
    def setUp(self):
        self.xml = """
      <SW_params n_types="2" label="PRB_31_plus_H">
      <comment> Stillinger and Weber, Phys. Rev. B  31 p 5262 (1984), extended for other elements </comment>
      <per_type_data type="1" atomic_num="1" />
      <per_type_data type="2" atomic_num="14" />
      <per_pair_data atnum_i="1" atnum_j="1" AA="0.0" BB="0.0"
      p="0" q="0" a="1.0" sigma="1.0" eps="0.0" />
      <per_pair_data atnum_i="1" atnum_j="14" AA="8.581214" BB="0.0327827"
      p="4" q="0" a="1.25" sigma="2.537884" eps="2.1672" />
      <per_pair_data atnum_i="14" atnum_j="14" AA="7.049556277" BB="0.6022245584"
      p="4" q="0" a="1.80" sigma="2.0951" eps="2.1675" />

      <!-- triplet terms: atnum_c is the center atom, neighbours j and k -->
      <per_triplet_data atnum_c="1"  atnum_j="1"  atnum_k="1"
      lambda="21.0" gamma="1.20" eps="2.1675" />
      <per_triplet_data atnum_c="1"  atnum_j="1"  atnum_k="14"
      lambda="21.0" gamma="1.20" eps="2.1675" />
      <per_triplet_data atnum_c="1"  atnum_j="14" atnum_k="14"
      lambda="21.0" gamma="1.20" eps="2.1675" />

      <per_triplet_data atnum_c="14" atnum_j="1"  atnum_k="1"
      lambda="21.0" gamma="1.20" eps="2.1675" />
      <per_triplet_data atnum_c="14" atnum_j="1"  atnum_k="14"
      lambda="21.0" gamma="1.20" eps="2.1675" />
      <per_triplet_data atnum_c="14" atnum_j="14" atnum_k="14"
      lambda="21.0" gamma="1.20" eps="2.1675" />
      </SW_params>
      """

        quippy.system_module.system_reseed_rng(2065775975)
        self.pot_calculator = Potential('IP SW', param_str=self.xml)

        self.at = Atoms('Si8', positions=diamond_pos, pbc=True, cell=[5.44, 5.44, 5.44])

        self.f = np.zeros((3, len(self.at)), order='F')
        self.df = np.zeros((3, len(self.at)), order='F')
        self.v = np.zeros((3, 3), order='F')

        self.energy_ref = -34.5038375509

        self.forces_ref = np.array([[0.89920374, -0.38025157, -0.38727027],
                                    [0.36623356, -0.52403757, 0.7200206],
                                    [-0.36952654, 0.12899529, 0.00458111],
                                    [-0.19912365, -0.1632057, 1.08509495],
                                    [-0.67565314, -0.59410498, -0.47921521],
                                    [0.17097454, 0.5847822, -0.31088749],
                                    [0.43613712, 0.90811269, 0.1600328],
                                    [-0.62824563, 0.03970963, -0.79235649]])

        self.virial_ref = np.array([[-0.34103601, 0.60925144, -0.02138795],
                                    [0.60925144, -0.36145702, -0.19375487],
                                    [-0.02138795, -0.19375487, -0.34640615]]).T

        # Voigt notation by hand from virial
        self.stress_ref = - np.array([-0.34103601, -0.36145702, -0.34640615,
                                      - 0.19375487, -0.02138795, 0.60925144]) / self.at.get_volume()

        self.at.calc = self.pot_calculator

    def test_energy(self):
        self.assertAlmostEqual(self.at.get_potential_energy(), self.energy_ref)

    def test_forces(self):
        self.assertArrayAlmostEqual(self.at.get_forces(), self.forces_ref, tol=1E-06)

    def test_stress(self):
        self.assertArrayAlmostEqual(self.at.get_stress(), self.stress_ref)

    def test_virial(self):
        self.assertArrayAlmostEqual(self.pot_calculator.get_virial(self.at), self.virial_ref, tol=1E-06)

    def test_calc_args_1(self):
        self.pot_calculator.calculate(self.at, propertes=["forces"], calc_args="do_rescale_E E_scale=1.01")
        f = self.pot_calculator.results['forces']
        self.assertArrayAlmostEqual(f, self.forces_ref*1.01, tol=1E-06)

    def test_calc_args_2(self):
        self.pot_calculator.calculate(self.at, properties=["forces"], do_rescale_E=True, E_scale=1.01)
        f = self.pot_calculator.results['forces']
        self.assertArrayAlmostEqual(f, self.forces_ref*1.01, tol=1E-06)

    def test_calc_args_3(self):
        pot2 = Potential('IP SW', param_str=self.xml, calc_args="do_rescale_E E_scale=1.01")
        f = pot2.get_forces(self.at)
        self.assertArrayAlmostEqual(f, self.forces_ref*1.01, tol=1E-06)

    def test_calc_args_4(self):
        pot2 = Potential('IP SW', param_str=self.xml, 
                                          calc_args={'do_rescale_E': True, 'E_scale': 1.01})
        f = pot2.get_forces(self.at)
        self.assertArrayAlmostEqual(f, self.forces_ref*1.01, tol=1E-06)

    # def test_numeric_forces(self):
    #    self.assertArrayAlmostEqual(self.pot.get_numeric_forces(self.at), self.f_ref.T, tol=1e-4)


class TestPotential(quippytest.QuippyTestCase):

    def test_get_potential_energy(self):
        np.random.seed(0)
        ats = [ Atoms('Al4', cell=(5, 5, 5), 
                    scaled_positions=np.random.uniform(size=(4, 3)), 
                    pbc=[True]*3) for _ in range(2) ]

        LJ_str="""<LJ_params n_types="1" label="default">
        <!-- dummy paramters for testing purposes, no physical meaning -->
        <per_type_data type="1" atomic_num="13" />
        <per_pair_data type1="1" type2="1" sigma="2.0" eps6="1.0" eps12="1.0" cutoff="6.0" energy_shift="T" linear_force_shift="F" />
        </LJ_params>
        """

        calc = Potential(param_str=LJ_str, args_str='IP LJ')
        E1 = []
        for at in ats:
            at.calc = calc
            at.calc.calculate(at, properties=['energy'])
            E1.append(at.calc.results['energy'])

        E2 = []
        for at in ats:
            at.calc = calc
            E2.append(at.get_potential_energy())
            
        self.assertArrayAlmostEqual(E1, E2)  
            
        RS_str = """
        <RS_params n_types="1" cutoff="10.0" label="default">
        <per_type_data type="1" atomic_num="13" />
        <per_pair_data type1="1" type2="1" sigma="1.0" eps="1.0" n="1">
           <lambda>-0.5</lambda>
           <sigma1>1.45</sigma1>
           <k>10</k>
        </per_pair_data>
        </RS_params>"""

        calc = Potential(param_str=RS_str, args_str='IP RS')
        E_RS_ref = [2.6570710989045994, 1.0933824843445803]
        
        E_RS = []
        for at in ats:
            at.calc = calc
            E_RS.append(at.get_potential_energy())
            
        self.assertArrayAlmostEqual(E_RS, E_RS_ref)  
            
if __name__ == '__main__':
    unittest.main()
