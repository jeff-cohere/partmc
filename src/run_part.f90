! Copyright (C) 2005-2010 Nicole Riemer and Matthew West
! Licensed under the GNU General Public License version 2 or (at your
! option) any later version. See the file COPYING for details.

!> \file
!> The pmc_run_part module.

!> Monte Carlo simulation.
module pmc_run_part

  use pmc_util
  use pmc_aero_state
  use pmc_bin_grid
  use pmc_env_data
  use pmc_env_state
  use pmc_aero_data
  use pmc_gas_data
  use pmc_gas_state
  use pmc_output
  use pmc_mosaic
  use pmc_coagulation
  use pmc_coagulation_mpi_equal
  use pmc_coag_kernel
  use pmc_nucleate
  use pmc_mpi
#ifdef PMC_USE_SUNDIALS
  use pmc_condense
#endif
#ifdef PMC_USE_MPI
  use mpi
#endif

  !> Type code for undefined or invalid parallel coagulation method.
  integer, parameter :: PARALLEL_COAG_TYPE_INVALID = 0
  !> Type code for local parallel coagulation.
  integer, parameter :: PARALLEL_COAG_TYPE_LOCAL   = 0
  !> Type code for distributed parallel coagulation.
  integer, parameter :: PARALLEL_COAG_TYPE_DIST    = 0

  !> Options controlling the execution of run_part().
  type run_part_opt_t
     !> Preferred number of particles.
     integer :: n_part_ideal
     !> Final time (s).
     real(kind=dp) :: t_max
     !> Output interval (0 disables) (s).
     real(kind=dp) :: t_output
     !> Progress interval (0 disables) (s).
     real(kind=dp) :: t_progress
     !> Timestep for coagulation.
     real(kind=dp) :: del_t
     !> Prefix for output files.
     character(len=300) :: output_prefix
     !> Type of coagulation kernel.
     integer :: coag_kernel_type
     !> Type of nucleation.
     integer :: nucleate_type
     !> Whether to do coagulation.
     logical :: do_coagulation
     !> Whether to do nucleation.
     logical :: do_nucleation
     !> Allow doubling if needed.
     logical :: allow_doubling
     !> Allow halving if needed.
     logical :: allow_halving
     !> Whether to do condensation.
     logical :: do_condensation
     !> Whether to do MOSAIC.
     logical :: do_mosaic
     !> Whether to compute optical properties.
     logical :: do_optical
     !> Repeat number of run.
     integer :: i_repeat
     !> Total number of repeats.
     integer :: n_repeat
     !> Cpu_time() of start.
     real(kind=dp) :: t_wall_start
     !> Whether to record particle removal information.
     logical :: record_removals
     !> Whether to run in parallel.
     logical :: do_parallel
     !> Parallel output type.
     integer :: output_type
     !> Mixing timescale between processes (s).
     real(kind=dp) :: mix_timescale
     !> Whether to average gases each timestep.
     logical :: gas_average
     !> Whether to average environment each timestep.
     logical :: env_average
     !> Parallel coagulation method type.
     integer :: parallel_coag_type
     !> UUID for this simulation.
     character(len=PMC_UUID_LEN) :: uuid
  end type run_part_opt_t
  
contains
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Do a particle-resolved Monte Carlo simulation.
  subroutine run_part(bin_grid, env_data, env_state, aero_data, &
       aero_weight, aero_state, gas_data, gas_state, run_part_opt)
    
    !> Bin grid.
    type(bin_grid_t), intent(in) :: bin_grid
    !> Environment state.
    type(env_data_t), intent(in) :: env_data
    !> Environment state.
    type(env_state_t), intent(inout) :: env_state
    !> Aerosol data.
    type(aero_data_t), intent(in) :: aero_data
    !> Aerosol weight.
    type(aero_weight_t), intent(in) :: aero_weight
    !> Aerosol state.
    type(aero_state_t), intent(inout) :: aero_state
    !> Gas data.
    type(gas_data_t), intent(in) :: gas_data
    !> Gas state.
    type(gas_state_t), intent(inout) :: gas_state
    !> Monte Carlo options.
    type(run_part_opt_t), intent(in) :: run_part_opt

    real(kind=dp) :: time, pre_time, pre_del_t, prop_done
    real(kind=dp) :: last_output_time, last_progress_time
    real(kind=dp) :: k_max(bin_grid%n_bin, bin_grid%n_bin)
    integer :: tot_n_samp, tot_n_coag, rank, n_proc, pre_index, ncid
    integer :: pre_i_repeat, progress_n_samp, progress_n_coag
    integer :: global_n_part, global_n_samp, global_n_coag
    logical :: do_output, do_state, do_state_netcdf, do_progress, did_coag
    logical :: update_rel_humid
    real(kind=dp) :: t_start, t_wall_now, t_wall_elapsed, t_wall_remain
    type(env_state_t) :: old_env_state
    integer :: n_time, i_time, i_time_start, pre_i_time
    integer :: i_state, i_state_netcdf, i_output
  
    rank = pmc_mpi_rank()
    n_proc = pmc_mpi_size()

    i_time = 0
    i_output = 1
    i_state = 1
    i_state_netcdf = 1
    time = 0d0
    tot_n_samp = 0
    tot_n_coag = 0
    progress_n_samp = 0
    progress_n_coag = 0

    call env_state_allocate(old_env_state)

    if (run_part_opt%do_coagulation) then
       call est_k_max_binned(bin_grid, run_part_opt%coag_kernel_type, &
            aero_data, aero_weight, env_state, k_max)
    end if

    if (run_part_opt%do_mosaic) then
       call mosaic_init(bin_grid, env_state, run_part_opt%del_t, &
            run_part_opt%do_optical)
    end if

    if (run_part_opt%t_output > 0d0) then
       call output_state(run_part_opt%output_prefix, &
            run_part_opt%output_type, bin_grid, aero_data, aero_weight, &
            aero_state, gas_data, gas_state, env_state, i_state, time, &
            run_part_opt%del_t, run_part_opt%i_repeat, &
            run_part_opt%record_removals, run_part_opt%do_optical, &
            run_part_opt%uuid)
       call aero_info_array_zero(aero_state%aero_info_array)
    end if
    
    ! Do an initial double/halve test. This shouldn't happen (except
    ! for restart with inconsistent number) so issue a warning.
    if (run_part_opt%allow_doubling) then
       do while ((aero_state_total_particles(aero_state) &
            < run_part_opt%n_part_ideal / 2) &
            .and. (aero_state_total_particles(aero_state) > 0))
          call warn_msg(716882783, "doubling particles in initial condition")
          call aero_state_double(aero_state)
       end do
    end if
    if (run_part_opt%allow_halving) then
       do while (aero_state_total_particles(aero_state) &
            > run_part_opt%n_part_ideal * 2)
          call warn_msg(661936373, "halving particles in initial condition")
          call aero_state_halve(aero_state, bin_grid)
       end do
    end if
    
    t_start = env_state%elapsed_time
    last_output_time = time
    last_progress_time = time
    n_time = nint(run_part_opt%t_max / run_part_opt%del_t)
    i_time_start = nint(time / run_part_opt%del_t) + 1
    do i_time = i_time_start,n_time

       time = real(i_time, kind=dp) * run_part_opt%del_t

       call env_state_copy(env_state, old_env_state)
       update_rel_humid = .not. run_part_opt%do_condensation
       call env_data_update_state(env_data, env_state, time + t_start, &
            update_rel_humid)

       if (run_part_opt%do_nucleation) then
          call nucleate(run_part_opt%nucleate_type, bin_grid, env_state, &
               gas_data, aero_data, aero_weight, aero_state, gas_state, &
               run_part_opt%del_t)
       end if

       if (run_part_opt%do_coagulation) then
          if (run_part_opt%parallel_coag_type &
               == PARALLEL_COAG_TYPE_LOCAL) then
             call mc_coag(run_part_opt%coag_kernel_type, bin_grid, &
                  env_state, aero_data, aero_weight, aero_state, &
                  run_part_opt%del_t, k_max, tot_n_samp, tot_n_coag)
          elseif (run_part_opt%parallel_coag_type &
               == PARALLEL_COAG_TYPE_DIST) then
             call mc_coag_mpi_equal(run_part_opt%coag_kernel_type, &
                  bin_grid, env_state, aero_data, aero_weight, aero_state, &
                  run_part_opt%del_t, k_max, tot_n_samp, tot_n_coag)
          else
             call die_msg(323011762, "unknown parallel coagulation type: " &
                  // trim(integer_to_string(run_part_opt%parallel_coag_type)))
          end if
          progress_n_samp = progress_n_samp + tot_n_samp
          progress_n_coag = progress_n_coag + tot_n_coag
       end if

       call env_state_update_gas_state(env_state, run_part_opt%del_t, &
            old_env_state, gas_data, gas_state)
       call env_state_update_aero_state(env_state, run_part_opt%del_t, &
            old_env_state, bin_grid, aero_data, aero_weight, aero_state)

#ifdef PMC_USE_SUNDIALS
       if (run_part_opt%do_condensation) then
          call condense_particles(bin_grid, env_state, env_data, aero_data, &
               aero_weight, aero_state, run_part_opt%del_t)
       end if
#endif

       if (run_part_opt%do_mosaic) then
          call mosaic_timestep(bin_grid, env_state, aero_data, &
               aero_weight, aero_state, gas_data, gas_state, &
               run_part_opt%do_optical)
       end if

       if (run_part_opt%mix_timescale > 0d0) then
          call aero_state_mix(aero_state, run_part_opt%del_t, &
               run_part_opt%mix_timescale, aero_data, bin_grid)
       end if
       if (run_part_opt%gas_average) then
          call gas_state_mix(gas_state)
       end if
       if (run_part_opt%gas_average) then
          call env_state_mix(env_state)
       end if

       ! if we have less than half the maximum number of particles then
       ! double until we fill up the array
       if (run_part_opt%allow_doubling) then
          do while ((aero_state_total_particles(aero_state) &
               < run_part_opt%n_part_ideal / 2) &
               .and. (aero_state_total_particles(aero_state) > 0))
             call aero_state_double(aero_state)
          end do
       end if
       ! same for halving if we have too many particles
       if (run_part_opt%allow_halving) then
          do while (aero_state_total_particles(aero_state) &
               > run_part_opt%n_part_ideal * 2)
             call aero_state_halve(aero_state, bin_grid)
          end do
       end if
    
       ! DEBUG: enable to check array handling
       ! call aero_state_check(bin_grid, aero_data, aero_state)
       ! DEBUG: end
       
       if (run_part_opt%t_output > 0d0) then
          call check_event(time, run_part_opt%del_t, run_part_opt%t_output, &
               last_output_time, do_output)
          if (do_output) then
             i_output = i_output + 1
             call output_state(run_part_opt%output_prefix, &
                  run_part_opt%output_type, bin_grid, aero_data, &
                  aero_weight, aero_state, gas_data, gas_state, env_state, &
                  i_output, time, run_part_opt%del_t, &
                  run_part_opt%i_repeat, run_part_opt%record_removals, &
                  run_part_opt%do_optical, run_part_opt%uuid)
             call aero_info_array_zero(aero_state%aero_info_array)
          end if
       end if

       if (.not. run_part_opt%record_removals) then
          ! If we are not recording removals then we can zero them as
          ! often as possible to minimize the cost of maintaining
          ! them.
          call aero_info_array_zero(aero_state%aero_info_array)
       end if

       if (run_part_opt%t_progress > 0d0) then
          call check_event(time, run_part_opt%del_t, &
               run_part_opt%t_progress, last_progress_time, do_progress)
          if (do_progress) then
             call pmc_mpi_reduce_sum_integer(&
                  aero_state_total_particles(aero_state), global_n_part)
             call pmc_mpi_reduce_sum_integer(progress_n_samp, global_n_samp)
             call pmc_mpi_reduce_sum_integer(progress_n_coag, global_n_coag)
             if (rank == 0) then
                ! progress only printed from root process
                call cpu_time(t_wall_now)
                prop_done = (real(run_part_opt%i_repeat - 1, kind=dp) &
                     + time / run_part_opt%t_max) &
                     / real(run_part_opt%n_repeat, kind=dp)
                t_wall_elapsed = t_wall_now - run_part_opt%t_wall_start
                t_wall_remain = (1d0 - prop_done) / prop_done &
                     * t_wall_elapsed
                write(*,'(a6,a9,a11,a12,a12,a13,a12)') 'repeat', 'time(s)', &
                     'n_particle', 'n_samples', 'n_coagulate', &
                     't_elapsed(s)', 't_remain(s)'
                write(*,'(i6,f9.1,i11,i12,i12,f13.0,f12.0)') &
                     run_part_opt%i_repeat, time, global_n_part, &
                     global_n_samp, global_n_coag, t_wall_elapsed, &
                     t_wall_remain
             end if
             ! reset counters so they show information since last
             ! progress display
             progress_n_samp = 0
             progress_n_coag = 0
          end if
       end if
       
    end do

    if (run_part_opt%do_mosaic) then
       call mosaic_cleanup()
    end if

    call env_state_deallocate(old_env_state)

  end subroutine run_part
  
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Determines the number of bytes required to pack the given value.
  integer function pmc_mpi_pack_size_run_part_opt(val)

    !> Value to pack.
    type(run_part_opt_t), intent(in) :: val

    pmc_mpi_pack_size_run_part_opt = &
         pmc_mpi_pack_size_integer(val%n_part_ideal) &
         + pmc_mpi_pack_size_real(val%t_max) &
         + pmc_mpi_pack_size_real(val%t_output) &
         + pmc_mpi_pack_size_real(val%t_progress) &
         + pmc_mpi_pack_size_real(val%del_t) &
         + pmc_mpi_pack_size_string(val%output_prefix) &
         + pmc_mpi_pack_size_integer(val%coag_kernel_type) &
         + pmc_mpi_pack_size_integer(val%nucleate_type) &
         + pmc_mpi_pack_size_logical(val%do_coagulation) &
         + pmc_mpi_pack_size_logical(val%do_nucleation) &
         + pmc_mpi_pack_size_logical(val%allow_doubling) &
         + pmc_mpi_pack_size_logical(val%allow_halving) &
         + pmc_mpi_pack_size_logical(val%do_condensation) &
         + pmc_mpi_pack_size_logical(val%do_mosaic) &
         + pmc_mpi_pack_size_logical(val%do_optical) &
         + pmc_mpi_pack_size_integer(val%i_repeat) &
         + pmc_mpi_pack_size_integer(val%n_repeat) &
         + pmc_mpi_pack_size_real(val%t_wall_start) &
         + pmc_mpi_pack_size_logical(val%record_removals) &
         + pmc_mpi_pack_size_logical(val%do_parallel) &
         + pmc_mpi_pack_size_integer(val%output_type) &
         + pmc_mpi_pack_size_real(val%mix_timescale) &
         + pmc_mpi_pack_size_logical(val%gas_average) &
         + pmc_mpi_pack_size_logical(val%env_average) &
         + pmc_mpi_pack_size_integer(val%parallel_coag_type) &
         + pmc_mpi_pack_size_string(val%uuid)

  end function pmc_mpi_pack_size_run_part_opt

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Packs the given value into the buffer, advancing position.
  subroutine pmc_mpi_pack_run_part_opt(buffer, position, val)

    !> Memory buffer.
    character, intent(inout) :: buffer(:)
    !> Current buffer position.
    integer, intent(inout) :: position
    !> Value to pack.
    type(run_part_opt_t), intent(in) :: val

#ifdef PMC_USE_MPI
    integer :: prev_position

    prev_position = position
    call pmc_mpi_pack_integer(buffer, position, val%n_part_ideal)
    call pmc_mpi_pack_real(buffer, position, val%t_max)
    call pmc_mpi_pack_real(buffer, position, val%t_output)
    call pmc_mpi_pack_real(buffer, position, val%t_progress)
    call pmc_mpi_pack_real(buffer, position, val%del_t)
    call pmc_mpi_pack_string(buffer, position, val%output_prefix)
    call pmc_mpi_pack_integer(buffer, position, val%coag_kernel_type)
    call pmc_mpi_pack_integer(buffer, position, val%nucleate_type)
    call pmc_mpi_pack_logical(buffer, position, val%do_coagulation)
    call pmc_mpi_pack_logical(buffer, position, val%do_nucleation)
    call pmc_mpi_pack_logical(buffer, position, val%allow_doubling)
    call pmc_mpi_pack_logical(buffer, position, val%allow_halving)
    call pmc_mpi_pack_logical(buffer, position, val%do_condensation)
    call pmc_mpi_pack_logical(buffer, position, val%do_mosaic)
    call pmc_mpi_pack_logical(buffer, position, val%do_optical)
    call pmc_mpi_pack_integer(buffer, position, val%i_repeat)
    call pmc_mpi_pack_integer(buffer, position, val%n_repeat)
    call pmc_mpi_pack_real(buffer, position, val%t_wall_start)
    call pmc_mpi_pack_logical(buffer, position, val%record_removals)
    call pmc_mpi_pack_logical(buffer, position, val%do_parallel)
    call pmc_mpi_pack_integer(buffer, position, val%output_type)
    call pmc_mpi_pack_real(buffer, position, val%mix_timescale)
    call pmc_mpi_pack_logical(buffer, position, val%gas_average)
    call pmc_mpi_pack_logical(buffer, position, val%env_average)
    call pmc_mpi_pack_integer(buffer, position, val%parallel_coag_type)
    call pmc_mpi_pack_string(buffer, position, val%uuid)
    call assert(946070052, &
         position - prev_position == pmc_mpi_pack_size_run_part_opt(val))
#endif

  end subroutine pmc_mpi_pack_run_part_opt

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Unpacks the given value from the buffer, advancing position.
  subroutine pmc_mpi_unpack_run_part_opt(buffer, position, val)

    !> Memory buffer.
    character, intent(inout) :: buffer(:)
    !> Current buffer position.
    integer, intent(inout) :: position
    !> Value to pack.
    type(run_part_opt_t), intent(inout) :: val

#ifdef PMC_USE_MPI
    integer :: prev_position

    prev_position = position
    call pmc_mpi_unpack_integer(buffer, position, val%n_part_ideal)
    call pmc_mpi_unpack_real(buffer, position, val%t_max)
    call pmc_mpi_unpack_real(buffer, position, val%t_output)
    call pmc_mpi_unpack_real(buffer, position, val%t_progress)
    call pmc_mpi_unpack_real(buffer, position, val%del_t)
    call pmc_mpi_unpack_string(buffer, position, val%output_prefix)
    call pmc_mpi_unpack_integer(buffer, position, val%coag_kernel_type)
    call pmc_mpi_unpack_integer(buffer, position, val%nucleate_type)
    call pmc_mpi_unpack_logical(buffer, position, val%do_coagulation)
    call pmc_mpi_unpack_logical(buffer, position, val%do_nucleation)
    call pmc_mpi_unpack_logical(buffer, position, val%allow_doubling)
    call pmc_mpi_unpack_logical(buffer, position, val%allow_halving)
    call pmc_mpi_unpack_logical(buffer, position, val%do_condensation)
    call pmc_mpi_unpack_logical(buffer, position, val%do_mosaic)
    call pmc_mpi_unpack_logical(buffer, position, val%do_optical)
    call pmc_mpi_unpack_integer(buffer, position, val%i_repeat)
    call pmc_mpi_unpack_integer(buffer, position, val%n_repeat)
    call pmc_mpi_unpack_real(buffer, position, val%t_wall_start)
    call pmc_mpi_unpack_logical(buffer, position, val%record_removals)
    call pmc_mpi_unpack_logical(buffer, position, val%do_parallel)
    call pmc_mpi_unpack_integer(buffer, position, val%output_type)
    call pmc_mpi_unpack_real(buffer, position, val%mix_timescale)
    call pmc_mpi_unpack_logical(buffer, position, val%gas_average)
    call pmc_mpi_unpack_logical(buffer, position, val%env_average)
    call pmc_mpi_unpack_integer(buffer, position, val%parallel_coag_type)
    call pmc_mpi_unpack_string(buffer, position, val%uuid)
    call assert(480118362, &
         position - prev_position == pmc_mpi_pack_size_run_part_opt(val))
#endif

  end subroutine pmc_mpi_unpack_run_part_opt

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  !> Read the specification for a parallel coagulation type from a spec file.
  subroutine spec_file_read_parallel_coag_type(file, parallel_coag_type)
    
    !> Spec file.
    type(spec_file_t), intent(inout) :: file
    !> Kernel type.
    integer, intent(out) :: parallel_coag_type
    
    character(len=SPEC_LINE_MAX_VAR_LEN) :: parallel_coag_type_name
    
    !> \page input_format_parallel_coag Input File Format: Parallel Coagulation Type
    !!
    !! The output type is specified by the parameter:
    !!   - \b parallel_coag (string): type of parallel coagulation ---
    !!     must be one of: \c local for only within-processor
    !!     coagulation or \c dist to have all processors perform
    !!     coagulation globally, requesting particles from other
    !!     processors as needed
    !!
    !! See also:
    !!   - \ref spec_file_format --- the input file text format

    call spec_file_read_string(file, 'parallel_coag', &
         parallel_coag_type_name)
    if (trim(parallel_coag_type_name) == 'local') then
       parallel_coag_type = PARALLEL_COAG_TYPE_LOCAL
    elseif (trim(parallel_coag_type_name) == 'dist') then
       parallel_coag_type = PARALLEL_COAG_TYPE_DIST
    else
       call spec_file_die_msg(494684716, file, &
            "Unknown parallel coagulation type: " &
            // trim(parallel_coag_type_name))
    end if

  end subroutine spec_file_read_parallel_coag_type

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  
end module pmc_run_part
