! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
! H0 X
! H0 X   libAtoms+QUIP: atomistic simulation library
! H0 X
! H0 X   Portions of this code were written by
! H0 X     Albert Bartok-Partay, Silvia Cereda, Gabor Csanyi, James Kermode,
! H0 X     Ivan Solt, Wojciech Szlachta, Csilla Varnai, Steven Winfield.
! H0 X
! H0 X   Copyright 2006-2010.
! H0 X
! H0 X   These portions of the source code are released under the GNU General
! H0 X   Public License, version 2, http://www.gnu.org/copyleft/gpl.html
! H0 X
! H0 X   If you would like to license the source code under different terms,
! H0 X   please contact Gabor Csanyi, gabor@csanyi.net
! H0 X
! H0 X   Portions of this code were written by Noam Bernstein as part of
! H0 X   his employment for the U.S. Government, and are not subject
! H0 X   to copyright in the USA.
! H0 X
! H0 X
! H0 X   When using this software, please cite the following reference:
! H0 X
! H0 X   http://www.libatoms.org
! H0 X
! H0 X  Additional contributions by
! H0 X    Alessio Comisso, Chiara Gattinoni, and Gianpietro Moras
! H0 X
! H0 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

!X
!X IPModel_GAP module  
!X
!% Module for Gaussian Approximation Potential.
!%
!% The IPModel_GAP object contains all the parameters read from a
!% 'GAP_params' XML stanza.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
#include "error.inc"

module IPModel_GAP_module

use error_module
use system_module, only : dp, inoutput, string_to_int, reallocate, system_timer , print, PRINT_NERD
use dictionary_module
use periodictable_module, only: total_elements
use extendable_str_module
use paramreader_module
use linearalgebra_module
use atoms_types_module
use atoms_module

use mpi_context_module
use QUIP_Common_module

#ifdef HAVE_GAP
use descriptors_module
use gp_predict_module
#endif

implicit none

private 

include 'IPModel_interface.h'

#ifdef GAP_VERSION
   integer, parameter :: gap_version = GAP_VERSION
#else
   integer, parameter :: gap_version = 0
#endif

! this stuff is here for now, but it should live somewhere else eventually
! lower down in the GP

public :: IPModel_GAP

type IPModel_GAP

  real(dp) :: cutoff = 0.0_dp                                  !% Cutoff for computing connection.

  real(dp) :: E_scale = 0.0_dp                                 !% scale factor for the potential 

  ! bispectrum parameters
  integer :: j_max = 0
  real(dp) :: z0 = 0.0_dp
  integer :: n_species = 0                                       !% Number of atomic types.
  integer, dimension(:), allocatable :: Z
  real(dp), dimension(total_elements) :: z_eff = 0.0_dp
  real(dp), dimension(total_elements) :: w_Z = 1.0_dp
  real(dp), dimension(total_elements) :: e0 = 0.0_dp

  ! qw parameters
  integer :: qw_l_max = 0
  integer :: qw_f_n = 0
  logical :: qw_do_q = .false.
  logical :: qw_do_w = .false.
  real(dp), allocatable :: qw_cutoff(:)
  integer, allocatable :: qw_cutoff_f(:)
  real(dp), allocatable :: qw_cutoff_r1(:)

  integer :: cosnx_l_max, cosnx_n_max

  real(dp), dimension(:), allocatable :: pca_mean, NormFunction
  real(dp), dimension(:,:), allocatable :: pca_matrix, RadialTransform

  logical :: do_pca = .false.

  character(len=256) :: coordinates             !% Coordinate system used in GAP database

  character(len=STRING_LENGTH) :: label

#ifdef HAVE_GAP
  type(gpSparse) :: my_gp
  type(descriptor), dimension(:), allocatable :: my_descriptor
#endif
  logical :: initialised = .false.
  type(extendable_str) :: command_line
  integer :: xml_version

end type IPModel_GAP

logical, private :: parse_in_ip, parse_in_gap_data, parse_matched_label, parse_in_ip_done
integer, private :: parse_n_row, parse_cur_row

type(IPModel_GAP), private, pointer :: parse_ip
type(extendable_str), save :: parse_cur_data

interface Initialise
  module procedure IPModel_GAP_Initialise_str
end interface Initialise

interface Finalise
  module procedure IPModel_GAP_Finalise
end interface Finalise

interface Print
  module procedure IPModel_GAP_Print
end interface Print

interface Calc
  module procedure IPModel_GAP_Calc
end interface Calc

contains

subroutine IPModel_GAP_Initialise_str(this, args_str, param_str)
  type(IPModel_GAP), intent(inout) :: this
  character(len=*), intent(in) :: args_str, param_str
  type(Dictionary) :: params

  integer :: i_coordinate
  real(dp) :: gap_variance_regularisation
  logical :: has_gap_variance_regularisation

  call Finalise(this)

  ! now initialise the potential
#ifndef HAVE_GAP
  call system_abort('IPModel_GAP_Initialise_str: must be compiled with HAVE_GAP')
#else

  call initialise(params)
  this%label=''

  call param_register(params, 'label', '', this%label, help_string="No help yet.  This source file was $LastChangedBy$")
  call param_register(params, 'E_scale', '1.0', this%E_scale, help_string="rescaling factor for the potential")
  call param_register(params, 'gap_variance_regularisation', '0.001', gap_variance_regularisation, &
     has_value_target=has_gap_variance_regularisation, help_string="Regularisation value for variance calculation.")

  if (.not. param_read_line(params, args_str, ignore_unknown=.true.,task='IPModel_SW_Initialise_str args_str')) &
  call system_abort("IPModel_GAP_Initialise_str failed to parse label from args_str="//trim(args_str))
  call finalise(params)

  call IPModel_GAP_read_params_xml(this, param_str)
  call gp_readXML(this%my_gp, param_str,label=trim(this%label))
  if (.not. this%my_gp%fitted) call system_abort('IPModel_GAP_Initialise_str: GAP model has not been fitted.')
  allocate(this%my_descriptor(this%my_gp%n_coordinate))

  this%cutoff = 0.0_dp
  do i_coordinate = 1, this%my_gp%n_coordinate
     call concat(this%my_gp%coordinate(i_coordinate)%descriptor_str," xml_version="//this%xml_version)
     call initialise(this%my_descriptor(i_coordinate),string(this%my_gp%coordinate(i_coordinate)%descriptor_str))
     this%cutoff = max(this%cutoff,cutoff(this%my_descriptor(i_coordinate)))
     if( has_gap_variance_regularisation) call gpCoordinates_initialise_variance_estimate(this%my_gp%coordinate(i_coordinate), gap_variance_regularisation)
  enddo

#endif  

end subroutine IPModel_GAP_Initialise_str

subroutine IPModel_GAP_Finalise(this)
  type(IPModel_GAP), intent(inout) :: this
#ifdef HAVE_GAP
  if (allocated(this%qw_cutoff)) deallocate(this%qw_cutoff)
  if (allocated(this%qw_cutoff_f)) deallocate(this%qw_cutoff_f)
  if (allocated(this%qw_cutoff_r1)) deallocate(this%qw_cutoff_r1)

  if (allocated(this%Z)) deallocate(this%Z)

  if (this%my_gp%initialised) call finalise(this%my_gp)


  this%cutoff = 0.0_dp
  this%j_max = 0
  this%z0 = 0.0_dp
  this%n_species = 0
  this%z_eff = 0.0_dp
  this%w_Z = 1.0_dp
  this%qw_l_max = 0
  this%qw_f_n = 0
  this%qw_do_q = .false.
  this%qw_do_w = .false.

  this%coordinates = ''

  this%label = ''
  this%initialised = .false.
#endif

  call finalise(this%command_line)

end subroutine IPModel_GAP_Finalise

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% The potential calculator: this routine computes energy, forces and the virial.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_GAP_Calc(this, at, e, local_e, f, virial, local_virial, args_str, mpi, error)
  type(IPModel_GAP), intent(inout) :: this
  type(Atoms), intent(inout) :: at
  real(dp), intent(out), optional :: e, local_e(:) !% \texttt{e} = System total energy, \texttt{local_e} = energy of each atom, vector dimensioned as \texttt{at%N}.  
  real(dp), intent(out), optional :: f(:,:), local_virial(:,:)   !% Forces, dimensioned as \texttt{f(3,at%N)}, local virials, dimensioned as \texttt{local_virial(9,at%N)} 
  real(dp), intent(out), optional :: virial(3,3)   !% Virial
  character(len=*), intent(in), optional :: args_str 
  type(MPI_Context), intent(in), optional :: mpi
  integer, intent(out), optional :: error

#ifdef HAVE_GAP
  real(dp), pointer :: w_e(:)
  real(dp) :: e_i, e_i_cutoff
  real(dp), dimension(:), allocatable   :: local_e_in, energy_per_coordinate
  real(dp), dimension(:,:,:), allocatable   :: virial_in
  integer :: d, i, j, n, m, i_coordinate, i_pos0

  real(dp), dimension(:,:), allocatable :: f_in

  real(dp), dimension(3) :: pos, f_gp
  real(dp), dimension(3,3) :: virial_i
  type(Dictionary) :: params
  logical, dimension(:), pointer :: atom_mask_pointer
  logical, dimension(:), allocatable :: mpi_local_mask
  logical :: has_atom_mask_name
  character(STRING_LENGTH) :: atom_mask_name, calc_local_gap_variance, calc_energy_per_coordinate
  real(dp) :: r_scale, E_scale

  real(dp) :: gap_variance_i_cutoff
  real(dp), dimension(:), allocatable :: gap_variance, local_gap_variance_in
  real(dp), dimension(:), pointer :: local_gap_variance_pointer
  real(dp), dimension(:,:), allocatable :: gap_variance_gradient_in
  real(dp), dimension(:,:), pointer :: gap_variance_gradient_pointer
  real(dp) :: gap_variance_regularisation
  logical :: do_rescale_r, do_rescale_E, do_gap_variance, print_gap_variance, do_local_gap_variance, do_energy_per_coordinate
  integer :: only_descriptor
  logical :: do_select_descriptor
  logical :: mpi_parallel_descriptor

  type(descriptor_data) :: my_descriptor_data
  type(extendable_str) :: my_args_str
  real(dp), dimension(:), allocatable :: gradPredict, grad_variance_estimate

  INIT_ERROR(error)

  if (present(e)) then
     e = 0.0_dp
  endif

  if (present(local_e)) then
     call check_size('Local_E',local_e,(/at%N/),'IPModel_GAP_Calc', error)
     local_e = 0.0_dp
  endif

  if (present(f)) then 
     call check_size('Force',f,(/3,at%N/),'IPModel_GAP_Calc', error)
     f = 0.0_dp
  end if

  if (present(virial)) then
     virial = 0.0_dp
  endif

  if (present(local_virial)) then
     call check_size('Local_virial',local_virial,(/9,at%N/),'IPModel_GAP_Calc', error)
     local_virial = 0.0_dp
  endif

  ! Has to be allocated as it's in the reduction clause.
  allocate(local_e_in(at%N))
  local_e_in = 0.0_dp

  allocate(energy_per_coordinate(this%my_gp%n_coordinate))
  energy_per_coordinate = 0.0_dp

  allocate(f_in(3,at%N))
  f_in = 0.0_dp

  allocate(virial_in(3,3,at%N))
  virial_in = 0.0_dp

  if (.not. assign_pointer(at, "weight", w_e)) nullify(w_e)

  ! initialise this one since param parser doesn't set it
  atom_mask_pointer => null()
  has_atom_mask_name = .false.
  atom_mask_name = ""
  only_descriptor = 0

   call initialise(params)
   
   call param_register(params, 'atom_mask_name', 'NONE',atom_mask_name,has_value_target=has_atom_mask_name, &
   help_string="Name of a logical property in the atoms object. For atoms where this property is true, energies, forces, virials etc. are " // &
    "calculated")
   call param_register(params, 'r_scale', '1.0',r_scale, has_value_target=do_rescale_r, help_string="Rescaling factor for distances. Default 1.0.")
   call param_register(params, 'E_scale', '1.0',E_scale, has_value_target=do_rescale_E, help_string="Rescaling factor for energy. Default 1.0.")

   call param_register(params, 'local_gap_variance', '', calc_local_gap_variance, help_string="Compute variance estimate of the GAP prediction per atom and return it in the Atoms object.")
   call param_register(params, 'print_gap_variance', 'F', print_gap_variance, help_string="Compute variance estimate of the GAP prediction per descriptor and prints it.")
   call param_register(params, 'gap_variance_regularisation', '0.001', gap_variance_regularisation, help_string="Regularisation value for variance calculation.")

   call param_register(params, 'only_descriptor', '0', only_descriptor, has_value_target=do_select_descriptor, help_string="Only select a single coordinate")
   call param_register(params, 'energy_per_coordinate', '', calc_energy_per_coordinate, help_string="Compute energy per GP coordinate and return it in the Atoms object.")

   call param_register(params, 'mpi_parallel_descriptor', 'F', mpi_parallel_descriptor, help_string="Do MPI parallelism over descriptor instances rather than atoms")

   if(present(args_str)) then
     if (.not. param_read_line(params,args_str,ignore_unknown=.true.,task='IPModel_GAP_Calc args_str')) &
       call system_abort("IPModel_GAP_Calc failed to parse args_str='"//trim(args_str)//"'")
     call finalise(params)

     if( has_atom_mask_name ) then
        if (.not. assign_pointer(at, trim(atom_mask_name) , atom_mask_pointer)) &
            call system_abort("IPModel_GAP_Calc did not find "//trim(atom_mask_name)//" property in the atoms object.")
     endif
     if (do_rescale_r .or. do_rescale_E) then
        RAISE_ERROR("IPModel_GAP_Calc: rescaling of potential at the calc() stage with r_scale and E_scale not yet implemented!", error)
     end if

     my_args_str = trim(args_str)
  else
     ! call parser to set defaults
     if (.not. param_read_line(params,"",ignore_unknown=.true.,task='IPModel_GAP_Calc args_str')) &
       call system_abort("IPModel_GAP_Calc failed to parse args_str='"//trim(args_str)//"'")
     call finalise(params)
     call initialise(my_args_str)
  endif

  call concat(my_args_str," xml_version="//this%xml_version)

  do_local_gap_variance = len_trim(calc_local_gap_variance) > 0
  do_gap_variance = do_local_gap_variance .or. print_gap_variance
  do_energy_per_coordinate = len_trim(calc_energy_per_coordinate) > 0

  ! Has to be allocated as it's in the reduction clause.
  allocate( local_gap_variance_in(at%N) )
  local_gap_variance_in = 0.0_dp
  allocate( gap_variance_gradient_in(3,at%N) )
  gap_variance_gradient_in = 0.0_dp

  if( present(mpi) ) then
     if(mpi%active) then
        if(has_atom_mask_name) then
           RAISE_ERROR("IPModel_GAP: atom_mask_name "//trim(atom_mask_name)//" present while running MPI version. &
              The use of atom_mask_name is intended for serial-compiled code called from an external parallel code, such as LAMMPS",error)
        endif

        if( has_property(at,"mpi_local_mask") ) then
           RAISE_ERROR("IPModel_GAP: mpi_local_mask property already present", error)
        endif

        if (.not. mpi_parallel_descriptor) then
           allocate(mpi_local_mask(at%N))
           call add_property_from_pointer(at,'mpi_local_mask',mpi_local_mask,error=error)

           call concat(my_args_str," atom_mask_name=mpi_local_mask")
        endif
     endif
  endif


  if(print_gap_variance) then
     call print('GAP_VARIANCE potential '//trim(this%label)//' calculating for '//this%my_gp%n_coordinate//' descriptors')
  end if

  loop_over_descriptors: do i_coordinate = 1, this%my_gp%n_coordinate
     if (do_select_descriptor .and. (this%my_gp%n_coordinate > 1)) then
        if (i_coordinate /= only_descriptor) then
           call print("GAP label="//trim(this%label)//" skipping coordinate "//i_coordinate, PRINT_NERD)
           cycle
        end if
     end if

     if (.not. mpi_parallel_descriptor) then ! If parallelising over atoms, not descriptors
        if(mpi%active) call descriptor_MPI_setup(this%my_descriptor(i_coordinate),at,mpi,mpi_local_mask,error)
     endif

     d = descriptor_dimensions(this%my_descriptor(i_coordinate))

     if(do_gap_variance) then
        call gpCoordinates_initialise_variance_estimate(this%my_gp%coordinate(i_coordinate), gap_variance_regularisation)
     endif

     if(present(f) .or. present(virial) .or. present(local_virial)) then
        if (allocated(gradPredict)) deallocate(gradPredict)
        allocate(gradPredict(d))

        if(allocated(grad_variance_estimate)) deallocate(grad_variance_estimate)
        allocate(grad_variance_estimate(d))
     end if     
     call calc(this%my_descriptor(i_coordinate),at,my_descriptor_data, &
        do_descriptor=.true.,do_grad_descriptor=present(f) .or. present(virial) .or. present(local_virial), args_str=trim(string(my_args_str)), error=error)
     PASS_ERROR(error)
     allocate(gap_variance(size(my_descriptor_data%x)))

     call system_timer('IPModel_GAP_Calc_gp_predict')

!$omp parallel default(none) private(i,gradPredict, grad_variance_estimate, e_i,n,m,j,pos,f_gp,e_i_cutoff,virial_i,i_pos0,gap_variance_i_cutoff) &
!$omp shared(this,at,i_coordinate,my_descriptor_data,e,virial,local_virial,local_e,do_gap_variance,do_local_gap_variance,gap_variance,f,do_energy_per_coordinate,mpi,mpi_parallel_descriptor) &
!$omp reduction(+:local_e_in,f_in,virial_in,local_gap_variance_in, gap_variance_gradient_in, energy_per_coordinate)

!$omp do schedule(dynamic)
     loop_over_descriptor_instances: do i = 1, size(my_descriptor_data%x)
        if( .not. my_descriptor_data%x(i)%has_data ) cycle

        if (mpi_parallel_descriptor .and. mpi%active) then
            ! This blocking strategy should yield a good, memory-local distribution of descriptors to processors
           if (.not. ((i - 1) * mpi%n_procs / size(my_descriptor_data%x)) == mpi%my_proc) cycle
        endif

        !call system_timer('IPModel_GAP_Calc_gp_predict')

        if(present(f) .or. present(virial) .or. present(local_virial)) then
           call reallocate(gradPredict,size(my_descriptor_data%x(i)%data(:)),zero=.true.)
           e_i =  gp_predict(this%my_gp%coordinate(i_coordinate) , xStar=my_descriptor_data%x(i)%data(:), gradPredict =  gradPredict, variance_estimate=gap_variance(i), do_variance_estimate=do_gap_variance, grad_variance_estimate=grad_variance_estimate)
        else
           e_i =  gp_predict(this%my_gp%coordinate(i_coordinate) , xStar=my_descriptor_data%x(i)%data(:), variance_estimate=gap_variance(i), do_variance_estimate=do_gap_variance)
        endif
        !call system_timer('IPModel_GAP_Calc_gp_predict')
        if(present(e) .or. present(local_e)) then

           e_i_cutoff = e_i * my_descriptor_data%x(i)%covariance_cutoff / size(my_descriptor_data%x(i)%ci)
           call print("GAPDEBUG ci="//my_descriptor_data%x(i)%ci//" e_i="//e_i//" e_i_cutoff="//e_i_cutoff, PRINT_NERD)

           do n = 1, size(my_descriptor_data%x(i)%ci)
              local_e_in( my_descriptor_data%x(i)%ci(n) ) = local_e_in( my_descriptor_data%x(i)%ci(n) ) + e_i_cutoff
           enddo
        endif

        if( do_energy_per_coordinate ) energy_per_coordinate(i_coordinate) = energy_per_coordinate(i_coordinate) + e_i * my_descriptor_data%x(i)%covariance_cutoff

        if( do_local_gap_variance ) then
           gap_variance_i_cutoff = gap_variance(i) * my_descriptor_data%x(i)%covariance_cutoff**2 / size(my_descriptor_data%x(i)%ci)

           do n = 1, size(my_descriptor_data%x(i)%ci)
              local_gap_variance_in( my_descriptor_data%x(i)%ci(n) ) = local_gap_variance_in( my_descriptor_data%x(i)%ci(n) ) + gap_variance_i_cutoff
           enddo
        endif

        if(present(f) .or. present(virial) .or. present(local_virial)) then
           i_pos0 = lbound(my_descriptor_data%x(i)%ii,1)

           do n = lbound(my_descriptor_data%x(i)%ii,1), ubound(my_descriptor_data%x(i)%ii,1)
              if( .not. my_descriptor_data%x(i)%has_grad_data(n) ) cycle
              j = my_descriptor_data%x(i)%ii(n)
              pos = my_descriptor_data%x(i)%pos(:,n)
              f_gp = matmul( gradPredict,my_descriptor_data%x(i)%grad_data(:,:,n)) * my_descriptor_data%x(i)%covariance_cutoff + &
              e_i * my_descriptor_data%x(i)%grad_covariance_cutoff(:,n)
              if( present(f) ) then
                 f_in(:,j) = f_in(:,j) - f_gp
              endif
              if( do_local_gap_variance ) then
                 gap_variance_gradient_in(:,j) = gap_variance_gradient_in(:,j) + & 
                    matmul( grad_variance_estimate, my_descriptor_data%x(i)%grad_data(:,:,n)) * my_descriptor_data%x(i)%covariance_cutoff**2 + &
                    2.0_dp * gap_variance(i) * my_descriptor_data%x(i)%covariance_cutoff * my_descriptor_data%x(i)%grad_covariance_cutoff(:,n)
              endif
              if( present(virial) .or. present(local_virial) ) then
                 virial_i = ((pos-my_descriptor_data%x(i)%pos(:,i_pos0)) .outer. f_gp)
                 virial_in(:,:,j) = virial_in(:,:,j) - virial_i

                 !virial_i = (pos .outer. f_gp) / size(my_descriptor_data%x(i)%ci)
                 !do m = 1, size(my_descriptor_data%x(i)%ci)
                 !   virial_in(:,:,my_descriptor_data%x(i)%ci(m)) = virial_in(:,:,my_descriptor_data%x(i)%ci(m)) - virial_i
                 !enddo
              endif
           enddo
        endif
     enddo loop_over_descriptor_instances
!$omp end do
     if(allocated(gradPredict)) deallocate(gradPredict)
!$omp end parallel
     call system_timer('IPModel_GAP_Calc_gp_predict')

     if(print_gap_variance) then
        if( size(my_descriptor_data%x) > 0 ) then
           do i = 1, size(my_descriptor_data%x)
              if( .not. my_descriptor_data%x(i)%has_data ) cycle
              call print('GAP_VARIANCE potential '//trim(this%label)//' descriptor '//i_coordinate//' var( '//i//' ) = '//(gap_variance(i))//" * "//(my_descriptor_data%x(i)%covariance_cutoff**2)//" cutoff")
              if(allocated(my_descriptor_data%x(i)%ii)) call print('GAP_VARIANCE potential '//trim(this%label)//' descriptor '//i_coordinate//' ii( '//i//' ) = '//my_descriptor_data%x(i)%ii)
           enddo
        else
           call print('GAP_VARIANCE potential '//trim(this%label)//' descriptor '//i_coordinate//' not found')
        endif
     endif
     if(allocated(gap_variance)) deallocate(gap_variance)

     call finalise(my_descriptor_data)

  enddo loop_over_descriptors

  if(present(f)) f = f_in
  if(present(e)) e = sum(local_e_in)
  if(present(local_e)) local_e = local_e_in
  if(present(virial)) virial = sum(virial_in,dim=3)

  if(present(local_virial)) then
     do i = 1, at%N
        local_virial(:,i) = reshape(virial_in(:,:,i),(/9/))
     enddo
  endif

  if(allocated(local_e_in)) deallocate(local_e_in)
  if(allocated(f_in)) deallocate(f_in)
  if(allocated(virial_in)) deallocate(virial_in)

  if (present(mpi)) then
     if( mpi%active ) then
        if(present(f)) call sum_in_place(mpi,f)
        if(present(virial)) call sum_in_place(mpi,virial)
        if(present(local_virial)) call sum_in_place(mpi,local_virial)
        if(present(e)) e = sum(mpi,e)
        if(present(local_e) ) call sum_in_place(mpi,local_e)
        if(do_local_gap_variance)  then
           call sum_in_place(mpi, local_gap_variance_in)
           if(present(f) .or. present(virial) .or. present(local_virial)) call sum_in_place(mpi, gap_variance_gradient_in)
        endif
        if(do_energy_per_coordinate) call sum_in_place(mpi,energy_per_coordinate)

        if (.not. mpi_parallel_descriptor) then
           call remove_property(at,'mpi_local_mask', error=error)
           deallocate(mpi_local_mask)
        endif
     endif
  endif

  if( do_local_gap_variance ) then
     call add_property(at, trim(calc_local_gap_variance), 0.0_dp, ptr = local_gap_variance_pointer, error=error)
     PASS_ERROR(error)
     local_gap_variance_pointer = local_gap_variance_in

     if(present(f) .or. present(virial) .or. present(local_virial)) then
        call add_property(at, "gap_variance_gradient", 0.0_dp, n_cols=3, ptr2 = gap_variance_gradient_pointer, error=error)
        PASS_ERROR(error)
        gap_variance_gradient_pointer = gap_variance_gradient_in
     endif
  endif

  if( do_energy_per_coordinate ) call set_param_value(at,trim(calc_energy_per_coordinate),energy_per_coordinate)

  if(allocated(local_gap_variance_in)) deallocate(local_gap_variance_in)
  if(allocated(gap_variance_gradient_in)) deallocate(gap_variance_gradient_in)
  if(allocated(energy_per_coordinate)) deallocate(energy_per_coordinate)

  if(present(e)) then
     if( associated(atom_mask_pointer) ) then
        e = e + sum(this%e0(at%Z),mask=atom_mask_pointer)
     else
        e = e + sum(this%e0(at%Z))
     endif
  endif

  if(present(local_e)) then
     if( associated(atom_mask_pointer) ) then
        where (atom_mask_pointer) local_e = local_e + this%e0(at%Z)
     else
        local_e = local_e + this%e0(at%Z)
     endif
  endif

  if(present(f)) f = this%E_scale * f
  if(present(e)) e = this%E_scale * e
  if(present(local_e)) local_e = this%E_scale * local_e
  if(present(virial)) virial = this%E_scale * virial
  if(present(local_virial)) local_virial = this%E_scale * local_virial
  
  atom_mask_pointer => null()
  local_gap_variance_pointer => null()
  gap_variance_gradient_pointer => null()
  call finalise(my_args_str)

#endif

end subroutine IPModel_GAP_Calc

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% XML param reader functions.
!% An example for XML stanza is given below, please notice that
!% they are simply dummy parameters for testing purposes, with no physical meaning.
!%
!%> <GAP_params datafile="file" label="default">
!%> </GAP_params>
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_startElement_handler(URI, localname, name, attributes)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 
  type(dictionary_t), intent(in) :: attributes

  integer :: status
  character(len=1024) :: value

  integer :: ri, Z

  if(name == 'GAP_params') then ! new GAP stanza
     
     if(parse_in_ip) &
        call system_abort("IPModel_startElement_handler entered GAP_params with parse_in true. Probably a bug in FoX (4.0.1, e.g.)")
     
     if(parse_matched_label) return ! we already found an exact match for this label
     
     call QUIP_FoX_get_value(attributes, 'label', value, status)
     if(status /= 0) value = ''
     
     if(len(trim(parse_ip%label)) > 0) then ! we were passed in a label
        if(value == parse_ip%label) then ! exact match
           parse_matched_label = .true.
           parse_in_ip = .true.
        else ! no match
           parse_in_ip = .false.
        endif
     else ! no label passed in
        parse_in_ip = .true.
        parse_ip%label = trim(value) ! if we found a label, AND didn't have one originally, pass it back to the object.
     endif

     if(parse_in_ip) then
        if(parse_ip%initialised) call finalise(parse_ip)
     endif


     call QUIP_FoX_get_value(attributes, 'gap_version', value, status)
     if( (status == 0) ) then
        parse_ip%xml_version = string_to_int(value)
        if( parse_ip%xml_version > gap_version ) &
        call system_abort( &
           'Database was created with a later version of the code.' // &
           'Version of code used to generate the database is '//trim(value)//'.'// &
           'Version of current code is '//gap_version//'. Please update your code.')
     else
        parse_ip%xml_version = 0
     endif

  elseif(parse_in_ip .and. name == 'GAP_data') then

     call QUIP_FoX_get_value(attributes, 'e0', value, status)
     if(status == 0) then
        read (value, *) parse_ip%e0(1)
        parse_ip%e0 = parse_ip%e0(1)
     endif

     call QUIP_FoX_get_value(attributes, 'do_pca', value, status)
     if(status == 0) then
        read (value, *) parse_ip%do_pca
     else
        parse_ip%do_pca = .false.
     endif

     allocate( parse_ip%Z(parse_ip%n_species) )
     parse_in_gap_data = .true.

  elseif(parse_in_ip .and. parse_in_gap_data .and. name == 'e0') then
     call QUIP_FoX_get_value(attributes, 'Z', value, status)
     if(status == 0) then
        read (value, *) Z
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find Z')
     endif
     if( Z > size(parse_ip%e0) ) call system_abort('IPModel_GAP_read_params_xml: attribute Z = '//Z//' > '//size(parse_ip%e0))

     call QUIP_FoX_get_value(attributes, 'value', value, status)
     if(status == 0) then
        read (value, *) parse_ip%e0(Z)
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find value in e0')
     endif

  elseif(parse_in_ip .and. name == 'water_monomer_params') then

     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cutoff
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif

  elseif(parse_in_ip .and. name == 'hf_dimer_params') then

     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cutoff
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif

  elseif(parse_in_ip .and. name == 'water_dimer_params') then

     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cutoff
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif

  elseif(parse_in_ip .and. name == 'bispectrum_so4_params') then

     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cutoff
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif

     call QUIP_FoX_get_value(attributes, 'j_max', value, status)
     if(status == 0) then
        read (value, *) parse_ip%j_max
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find j_max')
     endif

     call QUIP_FoX_get_value(attributes, 'z0', value, status)
     if(status == 0) then
        read (value, *) parse_ip%z0
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find z0')
     endif

  elseif(parse_in_ip .and. name == 'cosnx_params') then
  
     call QUIP_FoX_get_value(attributes, 'l_max', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cosnx_l_max
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find l_max')
     endif
  
     call QUIP_FoX_get_value(attributes, 'n_max', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cosnx_n_max
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find n_max')
     endif
  
     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%cutoff
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif
  
     allocate(parse_ip%NormFunction(parse_ip%cosnx_n_max), parse_ip%RadialTransform(parse_ip%cosnx_n_max,parse_ip%cosnx_n_max))

  elseif(parse_in_ip .and. name == 'qw_so3_params') then

     call QUIP_FoX_get_value(attributes, 'l_max', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_l_max
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find l_max')
     endif

     call QUIP_FoX_get_value(attributes, 'n_radial', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_f_n
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find n_radial')
     endif

     call QUIP_FoX_get_value(attributes, 'do_q', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_do_q
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find do_q')
     endif

     call QUIP_FoX_get_value(attributes, 'do_w', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_do_w
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find do_w')
     endif

     allocate(parse_ip%qw_cutoff(parse_ip%qw_f_n), parse_ip%qw_cutoff_f(parse_ip%qw_f_n), parse_ip%qw_cutoff_r1(parse_ip%qw_f_n))

  elseif(parse_in_ip .and. name == 'radial_function') then

     call QUIP_FoX_get_value(attributes, 'i', value, status)
     if(status == 0) then
        read (value, *) ri
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find i')
     endif

     call QUIP_FoX_get_value(attributes, 'cutoff', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_cutoff(ri)
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff')
     endif

     call QUIP_FoX_get_value(attributes, 'cutoff_type', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_cutoff_f(ri)
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff_type')
     endif

     call QUIP_FoX_get_value(attributes, 'cutoff_r1', value, status)
     if(status == 0) then
        read (value, *) parse_ip%qw_cutoff_r1(ri)
     else
        call system_abort('IPModel_GAP_read_params_xml cannot find cutoff_r1')
     endif

  elseif(parse_in_ip .and. name == 'NormFunction') then
  
     parse_n_row = parse_ip%cosnx_n_max
     call zero(parse_cur_data)
  
  elseif(parse_in_ip .and. name == 'command_line') then
      call zero(parse_cur_data)

  endif

end subroutine IPModel_startElement_handler

subroutine IPModel_endElement_handler(URI, localname, name)
  character(len=*), intent(in)   :: URI  
  character(len=*), intent(in)   :: localname
  character(len=*), intent(in)   :: name 

  character(len=100*parse_n_row) :: val

  if (parse_in_ip) then
    if(name == 'GAP_params') then
       parse_in_ip = .false.
       parse_in_ip_done = .true.
    elseif(name == 'GAP_data') then
       parse_in_gap_data = .false.

    elseif(name == 'bispectrum_so4_params') then

    elseif(name == 'hf_dimer_params') then

    elseif(name == 'water_monomer_params') then

    elseif(name == 'water_dimer_params') then

    elseif(name == 'qw_so3_params') then

    elseif(name == 'radial_function') then

    elseif(name == 'per_type_data') then

    elseif(name == 'PCA_mean') then
       
       val = string(parse_cur_data)
       read(val,*) parse_ip%pca_mean

    elseif(name == 'row') then

       val = string(parse_cur_data)
       read(val,*) parse_ip%pca_matrix(:,parse_cur_row)

    elseif(name == 'NormFunction') then
       
       val = string(parse_cur_data)
       read(val,*) parse_ip%NormFunction
    
    elseif(name == 'RadialTransform_row') then
    
       val = string(parse_cur_data)
       read(val,*) parse_ip%RadialTransform(:,parse_cur_row)

    elseif(name == 'command_line') then
       parse_ip%command_line = parse_cur_data
    end if
  endif

end subroutine IPModel_endElement_handler

subroutine IPModel_characters_handler(in)
   character(len=*), intent(in) :: in

   if(parse_in_ip) then
     call concat(parse_cur_data, in, keep_lf=.false.)
   endif

end subroutine IPModel_characters_handler

subroutine IPModel_GAP_read_params_xml(this, param_str)
  type(IPModel_GAP), intent(inout), target :: this
  character(len=*), intent(in) :: param_str

  type(xml_t) :: fxml

  if (len(trim(param_str)) <= 0) then
     call system_abort('IPModel_GAP_read_params_xml: invalid param_str length '//len(trim(param_str)) )
  else
     parse_in_ip = .false.
     parse_in_ip_done = .false.
     parse_matched_label = .false.
     parse_ip => this
     call initialise(parse_cur_data)

     call open_xml_string(fxml, param_str)
     call parse(fxml,  &
       startElement_handler = IPModel_startElement_handler, &
       endElement_handler = IPModel_endElement_handler, &
       characters_handler = IPModel_characters_handler)
     call close_xml_t(fxml)

     if(.not. parse_in_ip_done) &
     call  system_abort('IPModel_GAP_read_params_xml: could not initialise GAP potential. No GAP_params present?')
     this%initialised = .true.
  endif

end subroutine IPModel_GAP_read_params_xml

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
!X 
!% Printing of GAP parameters: number of different types, cutoff radius, atomic numbers, etc.
!X
!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

subroutine IPModel_GAP_Print (this, file, dict)
  type(IPModel_GAP), intent(inout) :: this
  type(Inoutput), intent(inout),optional :: file
  type(Dictionary), intent(inout), optional :: dict
  integer :: i

  real(dp), dimension(:), allocatable :: log_likelihood

#ifdef HAVE_GAP
  call Print("IPModel_GAP : Gaussian Approximation Potential", file=file)
  call Print("IPModel_GAP : label = "//this%label, file=file)
  call Print("IPModel_GAP : cutoff = "//this%cutoff, file=file)
  call Print("IPModel_GAP : E_scale = "//this%E_scale, file=file)
  call Print("IPModel_GAP : command_line = "//string(this%command_line),file=file)

  allocate(log_likelihood(this%my_gp%n_coordinate))
  do i = 1, this%my_gp%n_coordinate
     log_likelihood(i) = gp_log_likelihood(this%my_gp%coordinate(i))
  enddo

  call Print("IPModel_GAP : log likelihood = "//log_likelihood,file=file)
#else
  allocate(log_likelihood(1))
  log_likelihood = 0.0_dp
#endif

  if( present(dict) ) then
     if( dict%N == 0 ) call initialise(dict)
     call set_value(dict,"log_likelihood_"//trim(this%label),log_likelihood)
  endif

  if(allocated(log_likelihood)) deallocate(log_likelihood)

end subroutine IPModel_GAP_Print

end module IPModel_GAP_module
