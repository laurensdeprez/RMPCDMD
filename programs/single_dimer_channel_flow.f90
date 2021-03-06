program setup_single_dimer
  use rmpcdmd_module
  use hdf5
  use h5md_module
  use threefry_module
  use ParseText
  use iso_c_binding
  use omp_lib
  implicit none

  type(threefry_rng_t), allocatable :: state(:)
  
  integer, parameter :: N_species = 2

  type(cell_system_t) :: solvent_cells
  type(particle_system_t) :: solvent
  type(particle_system_t) :: colloids
  type(neighbor_list_t) :: neigh
  type(lj_params_t) :: solvent_colloid_lj
  type(lj_params_t) :: colloid_lj
  type(lj_params_t) :: walls_colloid_lj

  type(profile_t) :: vx

  integer :: rho
  integer :: N
  integer :: error
  integer, parameter :: n_bins_conc = 90
  double precision :: conc_z_cyl(n_bins_conc)   

  double precision :: sigma_N, sigma_C, max_cut
  double precision :: epsilon(3,2), shift
  double precision :: sigma(3,2), sigma_cut(3,2)
  double precision :: mass(2)

  double precision :: v_com(3), wall_v(3,2), wall_t(2)

  double precision :: e1, e2, e_wall
  double precision :: tau, dt , T
  double precision :: d,prob
  double precision :: skin, co_max, so_max
  integer :: N_MD_steps, N_loop
  integer :: n_extra_sorting
  double precision :: kin_e, temperature
  integer, dimension(N_species) :: n_solvent, catalytic_change, bulk_change
  type(h5md_element_t) :: n_solvent_el, catalytic_change_el, bulk_change_el

  double precision :: colloid_pos(3,2)
  type(h5md_file_t) :: hfile
  type(h5md_element_t) :: dummy_element
  integer(HID_T) :: fields_group
  type(h5md_element_t) :: rho_xy_el, vx_el
  type(thermo_t) :: thermo_data
  type(particle_system_io_t) :: dimer_io
  type(particle_system_io_t) :: solvent_io
  integer(HID_T) :: box_group

  type(PTo) :: config
  integer :: i, L(3),  n_threads
  integer :: j, k, m
  
  type(timer_t) :: flag_timer, change_timer, varia
  integer(HID_T) :: timers_group

  integer, allocatable :: rho_xy(:,:,:)

  double precision :: g(3) !gravity
  logical :: order, thermostat
  type(args_t) :: args

  args = get_input_args()
  call PTparse(config, args%input_file, 11)

  call flag_timer%init('flag')
  call change_timer%init('change')
  call varia%init('varia')

  n_threads = omp_get_max_threads()
  allocate(state(n_threads))
  call threefry_rng_init(state, args%seed)

  call h5open_f(error)

  g = 0
  g(1) = PTread_d(config, 'g')
  prob = PTread_d(config,'probability')

  L = PTread_ivec(config, 'L', 3)
  
  rho = PTread_i(config, 'rho')
  N = rho *L(1)*L(2)*L(3)

  T = PTread_d(config, 'T')
  thermostat = PTread_l(config, 'thermostat')
  d = PTread_d(config, 'd')
  order = PTread_l(config, 'order')

  wall_v = 0
  wall_t = [T, T]
  
  tau =PTread_d(config, 'tau')
  N_MD_steps = PTread_i(config, 'N_MD')
  dt = tau / N_MD_steps
  N_loop = PTread_i(config, 'N_loop')
  
  sigma_C = PTread_d(config, 'sigma_C')
  sigma_N = PTread_d(config, 'sigma_N')

  epsilon(:,1) = PTread_dvec(config, 'epsilon_C', N_species)
  epsilon(:,2) = PTread_dvec(config, 'epsilon_N', N_species)

  sigma(:,1) = sigma_C
  sigma(:,2) = sigma_N
  sigma_cut = sigma*2**(1.d0/6.d0)
  max_cut = maxval(sigma_cut)

  call solvent_colloid_lj% init(epsilon, sigma, sigma_cut)

  epsilon = 1.d0

  sigma(1,1) = 2*sigma_C
  sigma(1,2) = sigma_C + sigma_N
  sigma(2,1) = sigma_C + sigma_N
  sigma(2,2) = 2*sigma_N
  sigma_cut = sigma*2**(1.d0/6.d0)

  call colloid_lj% init(epsilon(1:2,:), sigma(1:2,:), sigma_cut(1:2,:))

  epsilon = 1.d0
  sigma(1,:) = [sigma_C, sigma_N]
  sigma_cut = sigma*3**(1.d0/6.d0)
  shift = max(sigma_C, sigma_N)*2**(1./6.) + 0.25
  call walls_colloid_lj% init(epsilon(1:1,:), sigma(1:1,:), sigma_cut(1:1,:), shift)
  write(*,*) epsilon(1:2,:), sigma(1:2,:), sigma_cut(1:2,:), shift
  

  mass(1) = rho * sigma_C**3 * 4 * 3.14159265/3
  mass(2) = rho * sigma_N**3 * 4 * 3.14159265/3
  write(*,*) 'mass =', mass

  call solvent% init(N,N_species)

  call colloids% init(2,2, mass) !there will be 2 species of colloids
  colloids% species(1) = 1
  colloids% species(2) = 2
  colloids% vel = 0

  call hfile%create(args%output_file, 'RMPCDMD::single_dimer_channel_flow', &
       'N/A', 'Pierre de Buyl')
  call thermo_data%init(hfile, n_buffer=50, step=N_MD_steps, time=N_MD_steps*dt)
  order = PTread_l(config, 'order')
  call PTkill(config)

  dimer_io%force_info%store = .false.
  dimer_io%id_info%store = .false.
  dimer_io%position_info%store = .true.
  dimer_io%position_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  dimer_io%position_info%step = N_MD_steps
  dimer_io%position_info%time = N_MD_steps*dt
  dimer_io%image_info%store = .true.
  dimer_io%image_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  dimer_io%image_info%step = N_MD_steps
  dimer_io%image_info%time = N_MD_steps*dt
  dimer_io%velocity_info%store = .true.
  dimer_io%velocity_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  dimer_io%velocity_info%step = N_MD_steps
  dimer_io%velocity_info%time = N_MD_steps*dt
  dimer_io%species_info%store = .true.
  dimer_io%species_info%mode = H5MD_FIXED
  call dimer_io%init(hfile, 'dimer', colloids)

  solvent_io%force_info%store = .false.
  solvent_io%id_info%store = .false.
  solvent_io%position_info%store = .true.
  solvent_io%position_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  solvent_io%position_info%step = N_loop*N_MD_steps
  solvent_io%position_info%time = N_loop*N_MD_steps*dt
  solvent_io%image_info%store = .true.
  solvent_io%image_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  solvent_io%image_info%step = N_loop*N_MD_steps
  solvent_io%image_info%time = N_loop*N_MD_steps*dt
  solvent_io%velocity_info%store = .true.
  solvent_io%velocity_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  solvent_io%velocity_info%step = N_loop*N_MD_steps
  solvent_io%velocity_info%time = N_loop*N_MD_steps*dt
  solvent_io%species_info%store = .true.
  solvent_io%species_info%mode = ior(H5MD_LINEAR,H5MD_STORE_TIME)
  solvent_io%species_info%step = N_loop*N_MD_steps
  solvent_io%species_info%time = N_loop*N_MD_steps*dt
  call solvent_io%init(hfile, 'solvent', solvent)

  solvent% force = 0
  solvent% species = 1
  call solvent_cells%init(L, 1.d0,has_walls = .true.)

  allocate(rho_xy(N_species, L(2), L(1)))
  call vx% init(0.d0, solvent_cells% edges(3), L(3))

  call h5gcreate_f(hfile%id, 'fields', fields_group, error)
  call rho_xy_el%create_time(fields_group, 'rho_xy', rho_xy, ior(H5MD_LINEAR,H5MD_STORE_TIME), &
       step=N_MD_steps, time=N_MD_steps*dt)
  call vx_el%create_time(fields_group, 'vx', vx%data, ior(H5MD_LINEAR,H5MD_STORE_TIME), &
       step=N_MD_steps, time=N_MD_steps*dt)
  call h5gclose_f(fields_group, error)

  call n_solvent_el%create_time(hfile%observables, 'n_solvent', &
       n_solvent, ior(H5MD_LINEAR,H5MD_STORE_TIME), step=N_MD_steps, &
       time=N_MD_steps*dt)
  call catalytic_change_el%create_time(hfile%observables, 'catalytic_change', &
       catalytic_change, ior(H5MD_LINEAR,H5MD_STORE_TIME), step=N_MD_steps, &
       time=N_MD_steps*dt)
  call bulk_change_el%create_time(hfile%observables, 'bulk_change', &
       bulk_change, ior(H5MD_LINEAR,H5MD_STORE_TIME), step=N_MD_steps, &
       time=N_MD_steps*dt)

  colloids%pos = spread(solvent_cells%edges / 2, dim=2, ncopies=size(colloids%pos, dim=2))

  if (order) then
     colloids%pos(1,2) = colloids%pos(1,2) + d
  else
     colloids%pos(1,1) = colloids%pos(1,1) + d
  end if

  call h5gcreate_f(dimer_io%group, 'box', box_group, error)
  call h5md_write_attribute(box_group, 'dimension', 3)
  call dummy_element%create_fixed(box_group, 'edges', solvent_cells%edges)
  call h5gclose_f(box_group, error)

  call h5gcreate_f(solvent_io%group, 'box', box_group, error)
  call h5md_write_attribute(box_group, 'dimension', 3)
  call dummy_element%create_fixed(box_group, 'edges', solvent_cells%edges)
  call h5gclose_f(box_group, error)

  call solvent% random_placement(solvent_cells% edges, colloids, solvent_colloid_lj)

  do i=1, solvent% Nmax
     solvent% vel(1,i) = threefry_normal(state(1))*sqrt(T)
     solvent% vel(2,i) = threefry_normal(state(1))*sqrt(T)
     solvent% vel(3,i) = threefry_normal(state(1))*sqrt(T)
  end do

  call solvent% sort(solvent_cells)

  call neigh% init(colloids% Nmax, 10*int(300*max(sigma_C,sigma_N)**3))

  skin = 1.5
  n_extra_sorting = 0

  call neigh% make_stencil(solvent_cells, max_cut+skin)

  call neigh% update_list(colloids, solvent, max_cut+skin, solvent_cells)

  e1 = compute_force(colloids, solvent, neigh, solvent_cells% edges, solvent_colloid_lj)
  e2 = compute_force_n2(colloids, solvent_cells% edges, colloid_lj)
  e_wall = lj93_zwall(colloids, solvent_cells% edges, walls_colloid_lj, 2)
  e_wall = e_wall + lj93_zwall(colloids, solvent_cells% edges, walls_colloid_lj, 3)
  solvent% force_old = solvent% force
  colloids% force_old = colloids% force
  catalytic_change = 0

  i = 0

  write(*,*) colloids% pos
  solvent_cells%bc = [PERIODIC_BC, BOUNCE_BACK_BC, BOUNCE_BACK_BC]

  write(*,*) 'Running for', N_loop, 'loops'
  !start RMPCDMD
  setup: do i = 1, N_loop
     if (modulo(i,20) == 0) write(*,'(i09)',advance='no') i
     md_loop: do j = 1, N_MD_steps
        call mpcd_stream_xforce_yzwall(solvent, solvent_cells, dt, g(1))

        colloids% pos_rattle = colloids% pos
        
        do k=1, colloids% Nmax
           colloids% pos(:,k) = colloids% pos(:,k) + dt * colloids% vel(:,k) + &
                dt**2 * colloids% force(:,k) / (2 * colloids% mass(k))
        end do
        call rattle_dimer_pos(colloids, d, dt, solvent_cells% edges)
   
        so_max = solvent% maximum_displacement()
        co_max = colloids% maximum_displacement()

        if ( (co_max >= skin/2) .or. (so_max >= skin/2) ) then
           call varia%tic()
           call apply_pbc(colloids, solvent_cells% edges)
           call apply_pbc(solvent, solvent_cells% edges)
           call varia%tac()
           call solvent% sort(solvent_cells)
           call neigh% update_list(colloids, solvent, max_cut + skin, solvent_cells)
           call varia%tic()
           solvent% pos_old = solvent% pos
           colloids% pos_old = colloids% pos
           call varia%tac()
           n_extra_sorting = n_extra_sorting + 1
        end if

        call switch(solvent% force, solvent% force_old)
        call switch(colloids% force, colloids% force_old)

        solvent% force = 0
        colloids% force = 0
        e1 = compute_force(colloids, solvent, neigh, solvent_cells% edges, solvent_colloid_lj)
        e2 = compute_force_n2(colloids, solvent_cells% edges, colloid_lj)
        e_wall = lj93_zwall(colloids, solvent_cells% edges, walls_colloid_lj, 2) + &
             lj93_zwall(colloids, solvent_cells% edges, walls_colloid_lj, 3)

        call md_vel_flow_partial(solvent, dt, g)
        do k=1, colloids% Nmax
           colloids% vel(:,k) = colloids% vel(:,k) + &
                dt * ( colloids% force(:,k) + colloids% force_old(:,k) ) / (2 * colloids% mass(k))
        end do
        call rattle_dimer_vel(colloids, d, dt, solvent_cells% edges)

        call flag_timer%tic()
        call flag_particles
        call flag_timer%tac()
        call change_timer%tic()
        call change_species
        call change_timer%tac()

     end do md_loop

     write(17,*) colloids% pos + colloids% image * spread(solvent_cells% edges, dim=2, ncopies=colloids% Nmax), &
                 colloids% vel, e1+e2+e_wall+(colloids% mass(1)*sum(colloids% vel(:,1)**2) &
                 +colloids% mass(2)*sum(colloids% vel(:,2)**2))/2 &
                 +sum(solvent% vel**2)/2
     call random_number(solvent_cells% origin)
     solvent_cells% origin = solvent_cells% origin - 1

     call apply_pbc(colloids, solvent_cells% edges)
     call apply_pbc(solvent, solvent_cells% edges)
     call solvent% sort(solvent_cells)
     call neigh% update_list(colloids, solvent, max_cut+skin, solvent_cells)
     solvent%pos_old = solvent% pos
     colloids%pos_old = colloids% pos

     call wall_mpcd_step(solvent, solvent_cells, state, &
          wall_temperature=wall_t, wall_v=wall_v, wall_n=[10, 10], bulk_temperature = T, thermostat=thermostat)
     
     temperature = compute_temperature(solvent, solvent_cells)
     kin_e = (colloids% mass(1)*sum(colloids% vel(:,1)**2) + &
          colloids% mass(2)*sum(colloids% vel(:,2)**2))/2 + &
          sum(solvent% vel**2)/2
     v_com = (sum(solvent% vel, dim=2) + mass(1)*colloids%vel(:,1) + mass(2)*colloids%vel(:,2)) / &
          (solvent%Nmax + mass(1) + mass(2))
     call thermo_data%append(hfile, temperature, e1+e2+e_wall, kin_e, e1+e2+e_wall+kin_e, v_com)

     call refuel

     call varia%tic()
     call compute_vx(solvent, vx)
     call vx% norm()
     call vx_el%append(vx%data)
     call vx% reset()
     call compute_rho_xy
     call varia%tac()
     call rho_xy_el%append(rho_xy)

     n_solvent = 0
     do k = 1, solvent%Nmax
        m = solvent%species(k)
        n_solvent(m) = n_solvent(m) + 1
     end do
     call n_solvent_el%append(n_solvent)
     call catalytic_change_el%append(catalytic_change)
     call bulk_change_el%append(bulk_change)

     call dimer_io%position%append(colloids%pos)
     call dimer_io%velocity%append(colloids%vel)
     call dimer_io%image%append(colloids%image)

  end do setup

  call thermo_data%append(hfile, temperature, e1+e2+e_wall, kin_e, e1+e2+e_wall+kin_e, v_com, add=.false., force=.true.)

  write(*,*) 'n extra sorting', n_extra_sorting

  call solvent_io%position%append(solvent%pos)
  call solvent_io%velocity%append(solvent%vel)
  call solvent_io%image%append(solvent%image)
  call solvent_io%species%append(solvent%species)

  call h5gcreate_f(hfile%id, 'timers', timers_group, error)
  call h5md_write_dataset(timers_group, solvent%time_stream%name, solvent%time_stream%total)
  call h5md_write_dataset(timers_group, solvent%time_md_vel%name, solvent%time_md_vel%total)
  call h5md_write_dataset(timers_group, solvent%time_step%name, solvent%time_step%total)
  call h5md_write_dataset(timers_group, solvent%time_count%name, solvent%time_count%total)
  call h5md_write_dataset(timers_group, solvent%time_sort%name, solvent%time_sort%total)
  call h5md_write_dataset(timers_group, solvent%time_ct%name, solvent%time_ct%total)
  call h5md_write_dataset(timers_group, solvent%time_max_disp%name, solvent%time_max_disp%total)
  call h5md_write_dataset(timers_group, flag_timer%name, flag_timer%total)
  call h5md_write_dataset(timers_group, neigh%time_update%name, neigh%time_update%total)
  call h5md_write_dataset(timers_group, varia%name, varia%total)
  call h5md_write_dataset(timers_group, neigh%time_force%name, neigh%time_force%total)

  call h5md_write_dataset(timers_group, 'total', solvent%time_stream%total + &
       solvent%time_step%total + solvent%time_count%total + solvent%time_sort%total + &
       solvent%time_ct%total + solvent%time_md_vel%total + solvent%time_max_disp%total + &
       flag_timer%total + change_timer%total + neigh%time_update%total + &
       varia%total + neigh%time_force%total)

  call h5gclose_f(timers_group, error)

  call rho_xy_el%close()
  call dimer_io%close()
  call hfile%close()
  call h5close_f(error)

contains

  subroutine flag_particles
    double precision :: dist_to_C_sq
    integer :: r, s
    double precision :: x(3)

    do s = 1,neigh% n(1)
       r = neigh%list(s,1)
       if (solvent% species(r) == 1) then
          x = rel_pos(colloids% pos(:,1),solvent% pos(:,r),solvent_cells% edges)
          dist_to_C_sq = dot_product(x, x)
          if (dist_to_C_sq < solvent_colloid_lj%cut_sq(1,1)) then
             if (threefry_double(state(1)) <= prob) then
                solvent% flag(r) = 1
             end if
          end if
       end if
    end do

  end subroutine flag_particles

  subroutine change_species
    double precision :: dist_to_C_sq
    double precision :: dist_to_N_sq
    integer :: m
    double precision :: x(3)

    catalytic_change = 0
    !$omp parallel do private(x, dist_to_C_sq, dist_to_N_sq) reduction(+:catalytic_change)
    do m = 1, solvent% Nmax
       if (solvent% flag(m) == 1) then
          x = rel_pos(colloids% pos(:,1), solvent% pos(:,m), solvent_cells% edges)
          dist_to_C_sq = dot_product(x, x)
          x = rel_pos(colloids% pos(:,2), solvent% pos(:,m), solvent_cells% edges)
          dist_to_N_sq = dot_product(x, x)
          if ( &
               (dist_to_C_sq > solvent_colloid_lj%cut_sq(1,1)) &
               .and. &
               (dist_to_N_sq > solvent_colloid_lj%cut_sq(1,2)) &
               ) &
               then
             solvent% species(m) = 2
             solvent% flag(m) = 0
             catalytic_change(1) = catalytic_change(1) - 1
             catalytic_change(2) = catalytic_change(2) + 1
          end if
       end if
    end do

  end subroutine change_species

  subroutine concentration_field_cylindrical
    double precision :: dimer_orient(3),x(3),y(3),z(3)
    double precision :: solvent_pos(3,solvent% Nmax)
    double precision :: dz,r,theta,x_pos,y_pos,z_pos
    integer :: o
    integer :: check
    logical :: far_enough_from_wall
    double precision :: range_min1(3),range_min2(3),range_max1(3),range_max2(3)
    
    dz = 2.d0*d/n_bins_conc
    dimer_orient = colloids% pos(:,2) - colloids% pos(:,1)
    z = dimer_orient/sqrt(dot_product(dimer_orient,dimer_orient))
   
    x = (/0.d0, 1.d0, -dimer_orient(2)/dimer_orient(3)/)
    x = x/sqrt(dot_product(x,x))
    y = (/z(2)*x(3)-z(3)*x(2),z(3)*x(1)-z(1)*x(3),z(1)*x(2)-z(2)*x(1)/)
    conc_z_cyl = 0

    range_min1 = colloids%pos(:,1) - d/2.0*z - (/0.d0,0.d0,1.d0/)*2*max_cut
    range_min2 = colloids%pos(:,1) - d/2.0*z + (/0.d0,0.d0,1.d0/)*2*max_cut
    range_max1 = colloids%pos(:,1) + 3.d0*d/2.0*z - (/0.d0,0.d0,1.d0/)*2*max_cut
    range_max2 = colloids%pos(:,1) - 3.d0*d/2.0*z + (/0.d0,0.d0,1.d0/)*2*max_cut

    if ( (range_min1(3)<solvent_cells%edges(3)).and.(range_min1(3)>0).and. &
       (range_max1(3)<solvent_cells%edges(3)).and.(range_max1(3)>0).and. &
       (range_min2(3)<solvent_cells%edges(3)).and.(range_min2(3)>0).and. &
       (range_max2(3)<solvent_cells%edges(3)).and.(range_max2(3)>0) ) then
       far_enough_from_wall = .true.
    else
       far_enough_from_wall = .false.
    end if 
    if (far_enough_from_wall) then
       do o = 1, solvent% Nmax
          solvent_pos(:,o) = solvent% pos(:,o) - colloids% pos(:,1)
          x_pos = dot_product(x,solvent_pos(:,o))
          y_pos = dot_product(y, solvent_pos(:,o))
          z_pos = dot_product(z, solvent_pos(:,o))
          solvent_pos(:,o) = (/x_pos,y_pos,z_pos/)
       end do
       do o = 1, solvent% Nmax
          r = sqrt(solvent_pos(1,o)**2 + solvent_pos(2,o)**2)
          theta = atan(solvent_pos(2,o)/solvent_pos(1,o))
          solvent_pos(1,o) = r
          solvent_pos(2,o) = theta
          if ((solvent_pos(1,o) < 2*max_cut).and.(solvent_pos(3,o)<1.5d0*d).and.(solvent_pos(3,o)>-0.5d0*d)) then
             if (solvent% species(o)==2) then
                check = floor((solvent_pos(3,o)+0.5d0*d)/dz)
                check = check+1 
                conc_z_cyl(check) = conc_z_cyl(check) + 1
             end if
          end if 
       end do
       colloid_pos(:,1) = 0
       colloid_pos(3,1) = colloids% pos(3,1)
       colloid_pos(:,2) = 0
       colloid_pos(3,2) = d + colloids% pos(3,1)
    else
       conc_z_cyl = 0
       colloid_pos = 0
    end if 
  end subroutine concentration_field_cylindrical

  subroutine md_vel_flow_partial(particles, dt, ext_force)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: dt
    double precision, intent(in) :: ext_force(3)

    integer :: k

    call solvent%time_md_vel%tic()
    !$omp parallel do
    do k = 1, particles% Nmax
       if (particles% wall_flag(k) == 0) then
          particles% vel(:,k) = particles% vel(:,k) + &
               dt * ( particles% force(:,k) + particles% force_old(:,k) ) / 2 &
               + dt*ext_force
       else
         particles% wall_flag(k) = 0
       end if
    end do
    call solvent%time_md_vel%tac()

  end subroutine md_vel_flow_partial

  subroutine compute_rho_xy
    integer :: i, s, ix, iy

    rho_xy = 0
    do i = 1, solvent%Nmax
       s = solvent%species(i)
       ix = modulo(floor(solvent%pos(1,i)/solvent_cells%a), L(1)) + 1
       iy = modulo(floor(solvent%pos(2,i)/solvent_cells%a), L(2)) + 1
       rho_xy(s, iy, ix) = rho_xy(s, iy, ix) + 1
    end do

  end subroutine compute_rho_xy

  subroutine refuel
    double precision :: dist_to_C_sq
    double precision :: dist_to_N_sq
    double precision :: far
    double precision :: x(3)
    integer :: n

    far = d + max_cut + 2

    !$omp parallel do private(x, dist_to_C_sq, dist_to_N_sq)
    do n = 1,solvent% Nmax
       if (solvent% species(n) == 2) then
          x = rel_pos(colloids% pos(:,1), solvent% pos(:,n), solvent_cells% edges)
          dist_to_C_sq = dot_product(x, x)
          x= rel_pos(colloids% pos(:,2), solvent% pos(:,n), solvent_cells% edges)
          dist_to_N_sq = dot_product(x, x)
          if ((dist_to_C_sq > far) .and. (dist_to_N_sq > far)) then
             solvent% species(n) = 1
          end if
       end if
    end do
  end subroutine refuel

end program setup_single_dimer
