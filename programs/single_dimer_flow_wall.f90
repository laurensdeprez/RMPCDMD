program setup_single_dimer
  use md
  use neighbor_list
  use common
  use cell_system
  use particle_system
  use hilbert
  use interaction
  use hdf5
  use h5md_module
  use particle_system_io
  use mpcd
  use threefry_module
  use ParseText
  use iso_c_binding
  use omp_lib
  implicit none

  type(threefry_rng_t), allocatable :: state(:)
  

  type(cell_system_t) :: solvent_cells
  type(particle_system_t) :: solvent
  type(particle_system_t) :: colloids
  type(neighbor_list_t) :: neigh
  type(lj_params_t) :: solvent_colloid_lj
  type(lj_params_t) :: colloid_lj
  type(lj_params_t) :: walls_colloid_lj

  type(profile_t) :: tz
  type(histogram_t) :: rhoz
  type(profile_t) :: vx

  type(h5md_file_t) :: datafile
  type(h5md_element_t) :: elem
  type(h5md_element_t) :: elem_tz, elem_tz_count, elem_vx_count
  type(h5md_element_t) :: elem_rhoz
  type(h5md_element_t) :: elem_vx
  type(h5md_element_t) :: elem_T
  type(h5md_element_t) :: elem_v_com
  integer(HID_T) :: box_group, solvent_group
  type(particle_system_io_t) :: solvent_io

  integer :: rho
  integer :: N
  integer :: error

  double precision :: sigma_N, sigma_C, max_cut
  double precision :: epsilon(2,2)
  double precision :: sigma(2,2), sigma_cut(2,2)
  double precision :: mass(2)

  double precision :: v_com(3), wall_v(3,2), wall_t(2)

  double precision :: e1, e2, e_wall
  double precision :: tau, dt , T
  double precision :: d,prob
  double precision :: skin, co_max, so_max
  integer :: N_MD_steps, N_loop
  integer :: n_extra_sorting
  double precision :: kin_co

  double precision :: conc_z(400)
  double precision :: colloid_pos(3,2)

  !type(PTo) :: config
  integer(c_int64_t) :: seed
  integer :: i, L(3),  n_threads
  integer :: j, k, m
  

  double precision :: g(3) !gravity
  logical :: fixed, on_track, stopped
  integer :: bufferlength
  fixed = .true.
  on_track = .true.
  stopped = .false.

  !call PTparse(config,get_input_filename(),11)

  

  n_threads = omp_get_max_threads()
  allocate(state(n_threads))
  
  seed = 742830

  do i = 1, n_threads
     state(i)%counter%c0 = 0
     state(i)%counter%c1 = 0
     state(i)%key%c0 = int(i, c_int64_t)
     state(i)%key%c1 = seed
  end do

  call h5open_f(error)

  g = [0.001d0, 0.d0, 0.d0] !PTread_ivec(config, 'g', 3) !place in inputfile
  bufferlength = 20 !PTread_i(config, 'bufferlength')
  prob = 1.d0 !PTread_d(config,'probability')

  L = [50,50,15] !PTread_ivec(config, 'L', 3)
  L(1) = L(1)+ bufferlength
  
  rho = 10 !PTread_i(config, 'rho')
  N = rho *L(1)*L(2)*L(3)

  T = 5.d0 !PTread_d(config, 'T')
  d = 4.5d0 !PTread_d(config, 'd')

  wall_v = 0
  wall_t = [T, T]
  
  tau =0.1d0 !PTread_d(config, 'tau')
  N_MD_steps = 10 !PTread_i(config, 'N_MD')
  dt = tau / N_MD_steps
  N_loop = 10000 !PTread_i(config, 'N_loop')

  

  sigma_C = 2.d0 !PTread_d(config, 'sigma_C')
  sigma_N = 2.d0 !PTread_d(config, 'sigma_N')
  
  epsilon(1,:) = [1.d0, 0.1d0] !PTread_dvec(config, 'epsilon_C', 2)
  epsilon(2,:) = [1.d0, 1.d0] !PTread_dvec(config, 'epsilon_N', 2)

  sigma(1,:) = sigma_C
  sigma(2,:) = sigma_N
  sigma_cut = sigma*2**(1.d0/6.d0)
  max_cut = maxval(sigma_cut)

  call solvent_colloid_lj% init(epsilon, sigma, sigma_cut)

  epsilon(1,1) = 1.d0 !PTread_d(config, 'epsilon_C_C')
  epsilon(1,2) = 1.d0 !PTread_d(config, 'epsilon_N_C')
  epsilon(2,1) = 1.d0 !PTread_d(config, 'epsilon_N_C')
  epsilon(2,2) = 1.d0 !PTread_d(config, 'epsilon_N_N')

  sigma(1,1) = 2*sigma_C
  sigma(1,2) = sigma_C + sigma_N
  sigma(2,1) = sigma_C + sigma_N
  sigma(2,2) = 2*sigma_N
  sigma_cut = sigma*2**(1.d0/6.d0)

  call colloid_lj% init(epsilon, sigma, sigma_cut)

  epsilon(1,1) = 1.d0 
  epsilon(1,2) = 1.d0 
  epsilon(2,1) = 1.d0 
  epsilon(2,2) = 1.d0 
  sigma(1,:) = [sigma_C, sigma_N]
  sigma(2,:) = [sigma_C, sigma_N]
  sigma_cut = sigma*2**(1.d0/6.d0)

  call walls_colloid_lj% init(epsilon, sigma, sigma_cut)

  mass(1) = rho * sigma_C**3 * 4 * 3.14159265/3
  mass(2) = rho * sigma_N**3 * 4 * 3.14159265/3
  write(*,*) 'mass =', mass

  call solvent% init(N,2) !there will be 2 species of solvent particles

  call colloids% init(2,2, mass) !there will be 2 species of colloids

  !call PTkill(config)
  
  open(17,file ='dimerdata_FullExp_1.txt')
  open(18,file ='dimerdata_FullExp_2.txt')
  open(19,file ='dimerdata_vx_flow_wall.txt')  

  colloids% species(1) = 1
  colloids% species(2) = 2
  colloids% vel = 0
  
  do i=1, solvent% Nmax
     solvent% vel(1,i) = threefry_normal(state(1))
     solvent% vel(2,i) = threefry_normal(state(1))
     solvent% vel(3,i) = threefry_normal(state(1))
  end do
  solvent%vel = solvent%vel*sqrt(T)
  v_com = sum(solvent% vel, dim=2) / size(solvent% vel, dim=2)
  solvent% vel = solvent% vel - spread(v_com, dim=2, ncopies=size(solvent% vel, dim=2))

  solvent% force = 0

  do m = 1, solvent% Nmax
     if (solvent% pos(2,m) < (L(2)/2.d0)) then
        solvent% species(m) = 1
     else
        solvent% species(m) = 2
     end if
  end do

  call solvent_cells%init(L, 1.d0,has_walls = .true.)
  colloids% pos(3,1) = solvent_cells% edges(3)/2.d0
  colloids% pos(3,2) = solvent_cells% edges(3)/2.d0 
  colloids% pos(1,1) = sigma_C*2**(1.d0/6.d0)+0.1d0
  colloids% pos(1,2) = colloids% pos(1,1) + d
  colloids% pos(2,:) = solvent_cells% edges(2)/2.d0 + 1.5d0*sigma_C
  
  write(*, *) colloids% pos  

  call solvent% random_placement(solvent_cells% edges, colloids, solvent_colloid_lj)

  call solvent% sort(solvent_cells)

  call neigh% init(colloids% Nmax, 10*int(300*max(sigma_C,sigma_N)**3))

  skin = 1.5
  n_extra_sorting = 0

  call neigh% make_stencil(solvent_cells, max_cut+skin)

  call neigh% update_list(colloids, solvent, max_cut+skin, solvent_cells)

  e1 = compute_force(colloids, solvent, neigh, solvent_cells% edges, solvent_colloid_lj)
  e2 = compute_force_n2(colloids, solvent_cells% edges, colloid_lj)
  !e_wall = colloid_wall_interaction(colloids, walls_colloid_lj,solvent_cells% edges)
  solvent% force_old = solvent% force
  colloids% force_old = colloids% force
  write(*,*) colloids% force
  write(*,*) ''
  write(*,*) '    i           |    e co so     |   e co co     |   kin co      |   kin so      |   total       |   temp        |'
  write(*,*) ''

  call vx% init(0.d0, solvent_cells% edges(3), L(3))

  kin_co = (mass(1)*sum(colloids% vel(:,1)**2)+mass(2)*sum(colloids% vel(:,2)**2))/2
  call thermo_write
  !start RMPCDMD
  setup: do i = 1, N_loop
     md: do j = 1, N_MD_steps
        call mpcd_stream_zwall_light(solvent, solvent_cells, dt,g)

        colloids% pos_rattle = colloids% pos
        
        if (.not. fixed) then
           if (on_track) then
              !only update the flow direction
              do k=1, colloids% Nmax
                 colloids% pos(1,k) = colloids% pos(1,k) + dt * colloids% vel(1,k) + &
                      dt**2 * colloids% force(1,k) / (2 * colloids% mass(k))
              end do
           else
              do k=1, colloids% Nmax
                 colloids% pos(:,k) = colloids% pos(:,k) + dt * colloids% vel(:,k) + &
                      dt**2 * colloids% force(:,k) / (2 * colloids% mass(k))
              end do
           end if 
           call rattle_dimer_pos(colloids, d, dt, solvent_cells% edges)
        end if     
        
        do k=1, colloids% Nmax 
           if (colloids% pos(1,k) > bufferlength) then
              on_track = .false.
              write(*,*) on_track
           end if 
        end do

        do k=1, colloids% Nmax 
           if (colloids% pos(1,k) > solvent_cells% edges(1)) then
              stopped = .true.
              write(*,*) stopped
           end if 
        end do

        if (stopped) exit setup

        so_max = solvent% maximum_displacement()
        co_max = colloids% maximum_displacement()

        if ( (co_max >= skin/2) .or. (so_max >= skin/2) ) then
           call apply_pbc(solvent, solvent_cells% edges)
           call apply_pbc(colloids, solvent_cells% edges)
           call solvent% sort(solvent_cells)
           call neigh% update_list(colloids, solvent, max_cut + skin, solvent_cells)
           solvent% pos_old = solvent% pos
           colloids% pos_old = colloids% pos
           n_extra_sorting = n_extra_sorting + 1
        end if

        call buffer_particles(solvent,solvent_cells% edges(:), bufferlength)

        call switch(solvent% force, solvent% force_old)
        call switch(colloids% force, colloids% force_old)

        solvent% force = 0
        colloids% force = 0
        e1 = compute_force(colloids, solvent, neigh, solvent_cells% edges, solvent_colloid_lj)
        e2 = compute_force_n2(colloids, solvent_cells% edges, colloid_lj)
        if (.not. on_track) then
           e_wall = colloid_wall_interaction(colloids, walls_colloid_lj,solvent_cells% edges)
        end if 
        if (on_track) then
           colloids% force(2,:) = 0
           colloids% force(3,:) = 0
           if (fixed) then
              colloids% force(1,:) = 0
           end if 
        end if 

        call md_vel_flow_partial(solvent, solvent_cells% edges, dt, g)
        if (.not. fixed) then
           if (on_track) then
              !only update in the direction of the flow
              do k=1, colloids% Nmax
                 colloids% vel(1,k) = colloids% vel(1,k) + &
                   dt * ( colloids% force(1,k) + colloids% force_old(1,k) ) / (2 * colloids% mass(k))
              end do
           else
              do k=1, colloids% Nmax
                 colloids% vel(:,k) = colloids% vel(:,k) + &
                   dt * ( colloids% force(:,k) + colloids% force_old(:,k) ) / (2 * colloids% mass(k))
              end do
           end if
           call rattle_dimer_vel(colloids, d, dt, solvent_cells% edges)
        end if 
        if (.not.fixed) then
           call flag_particles
           call change_species
        end if

     end do md

     

     write(17,*) colloids% pos + colloids% image * spread(solvent_cells% edges, dim=2, ncopies=colloids% Nmax), &
                 colloids% vel, e1+e2+e_wall+(colloids% mass(1)*sum(colloids% vel(:,1)**2) &
                 +colloids% mass(2)*sum(colloids% vel(:,2)**2))/2 &
                 +sum(solvent% vel**2)/2
     call random_number(solvent_cells% origin)
     solvent_cells% origin = solvent_cells% origin - 1

     call compute_vx(solvent, vx)
     if (modulo(i, 50) == 0) then
        call vx% norm()
        write(19,*) vx% data
        flush(19)
        call vx% reset()
     end if

     call solvent% sort(solvent_cells)
     call neigh% update_list(colloids, solvent, max_cut+skin, solvent_cells)

     call wall_mpcd_step(solvent, solvent_cells, state, &
          wall_temperature=wall_t, wall_v=wall_v, wall_n=[10, 10], bulk_temperature = T)
     
     kin_co = (colloids% mass(1)*sum(colloids% vel(:,1)**2)+ colloids% mass(2)*sum(colloids% vel(:,2)**2))/2
     call thermo_write
     if (mod(i,10)==0) then
        write(*,*) colloids% pos
        write(*,*) colloids% force
     end if
      
     if (i .gt. 2000) then
        fixed = .false.
     end if
  end do setup

  write(*,*) colloids% pos

  write(*,*) 'n extra sorting', n_extra_sorting
  
  call h5close_f(error)
  
  write(*,'(a16,f8.3)') solvent%time_stream%name, solvent%time_stream%total
  write(*,'(a16,f8.3)') solvent%time_step%name, solvent%time_step%total
  write(*,'(a16,f8.3)') solvent%time_count%name, solvent%time_count%total
  write(*,'(a16,f8.3)') solvent%time_sort%name, solvent%time_sort%total
  write(*,'(a16,f8.3)') solvent%time_ct%name, solvent%time_ct%total
  write(*,'(a16,f8.3)') 'total                          ', &
       solvent%time_stream%total + solvent%time_step%total + solvent%time_count%total +&
       solvent%time_sort%total + solvent%time_ct%total
  
contains

  subroutine thermo_write
    write(*,'(1i16,6f16.3,1e16.8)') i, e1, e2, &
         kin_co, sum(solvent% vel**2)/2, &
         e1+e2+e_wall+kin_co+sum(solvent% vel**2)/2, &
         compute_temperature(solvent, solvent_cells), &
         sqrt(dot_product(colloids% pos(:,1) - colloids% pos(:,2),colloids% pos(:,1) - colloids% pos(:,2))) - d
  end subroutine thermo_write


  subroutine flag_particles
  double precision :: dist_to_C_sq
  real :: rndnumbers(solvent% Nmax)
  integer :: r
  double precision :: x(3)
  
  call random_number(rndnumbers)
  
  do  r = 1,solvent% Nmax
     if (solvent% species(r) == 1) then
       x = rel_pos(colloids% pos(:,1),solvent% pos(:,r),solvent_cells% edges) 
       dist_to_C_sq = dot_product(x, x)
       if (dist_to_C_sq < solvent_colloid_lj%cut_sq(1,1)) then
         if (rndnumbers(r) <= prob) then
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

    do m = 1, solvent% Nmax
       if (solvent% flag(m) == 1) then
          x = rel_pos(colloids% pos(:,1), solvent% pos(:,m), solvent_cells% edges)
          dist_to_C_sq = dot_product(x, x)
          x = rel_pos(colloids% pos(:,2), solvent% pos(:,m), solvent_cells% edges)
          dist_to_N_sq = dot_product(x, x)
          if ( &
               (dist_to_C_sq > solvent_colloid_lj%cut_sq(1, 1)) &
               .and. &
               (dist_to_N_sq > solvent_colloid_lj%cut_sq(2, 1)) &
               ) &
               then
             solvent% species(m) = 2
             solvent% flag(m) = 0
          end if
       end if
    end do

  end subroutine change_species
  
  subroutine refuel
    double precision :: dist_to_C_sq
    double precision :: dist_to_N_sq
    double precision :: far
    double precision :: x(3)
    integer :: n

    far = (L(1)*0.45)**2


    do n = 1,solvent% Nmax 
       if (solvent% pos(1,n) > bufferlength) then
          if (solvent% species(n) == 2) then
             x = rel_pos(colloids% pos(:,1), solvent% pos(:,n), solvent_cells% edges)
             dist_to_C_sq = dot_product(x, x)
             x= rel_pos(colloids% pos(:,2), solvent% pos(:,n), solvent_cells% edges)
             dist_to_N_sq = dot_product(x, x)
             if ((dist_to_C_sq > far) .and. (dist_to_N_sq > far)) then
                solvent% species(n) = 1
             end if
          end if
       end if
    end do
  end subroutine refuel

  subroutine concentration_field
    double precision :: dimer_orient(3),x(3),y(3),z(3)
    double precision :: solvent_pos(3,solvent% Nmax)
    double precision :: dz,r,theta,x_pos,y_pos,z_pos
    integer :: o
    integer :: check

    dz = solvent_cells% edges(3)/400.d0
    dimer_orient = colloids% pos(:,2) - colloids% pos(:,1)
    z = dimer_orient/sqrt(dot_product(dimer_orient,dimer_orient))
    x = (/0.d0, 1.d0, -dimer_orient(2)/dimer_orient(3)/)
    x = x/sqrt(dot_product(x,x))
    y = (/z(2)*x(3)-z(3)*x(2),z(3)*x(1)-z(1)*x(3),z(1)*x(2)-z(2)*x(1)/)
    conc_z = 0

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
       solvent_pos(3,o) = solvent_pos(3,o)+colloids% pos(3,1)
       if (solvent% species(o)==2) then
          check = floor(solvent_pos(3,o)/dz)
          conc_z(check) = conc_z(check) + 1
       end if 
    end do
    colloid_pos(:,1) = 0
    colloid_pos(3,1) = colloids% pos(3,1)
    colloid_pos(:,2) = 0
    colloid_pos(3,2) = d + colloids% pos(3,1)
  end subroutine concentration_field
  
  function colloid_wall_interaction(colloids, walls_colloid_lj,edges) result(e)
     type(particle_system_t), intent(inout) :: colloids
     type(lj_params_t), intent(in) :: walls_colloid_lj
     double precision, intent(in) :: edges(3)
     double precision :: e

     integer :: k
     integer :: s
     double precision :: r_sq1, d1(3), r_sq2, d2(3),f1(3),f2(3)

     f1= 0.d0
     f2 = 0.d0
     e = 0.d0
     do k = 1, colloids% Nmax
        s = colloids% species(k)
        d1 = rel_pos(colloids% pos(:,k), [edges(1)/2.d0, edges(2)/2.d0,0.d0],edges)
        d2 = rel_pos(colloids% pos(:,k), [edges(1)/2.d0, edges(2)/2.d0,edges(3)],edges)
        r_sq1 = dot_product(d1,d1)
        r_sq2 = dot_product(d2,d2)
        if (r_sq1 <= walls_colloid_lj% cut_sq(1,s)) then
           f1 = lj_force_9_6(d1, r_sq1, walls_colloid_lj% epsilon(1,s), walls_colloid_lj% sigma(1,s))
           e = e + lj_energy_9_6(r_sq1, walls_colloid_lj% epsilon(1,s), walls_colloid_lj% sigma(1,s))
        end if
        if (r_sq2 <= walls_colloid_lj% cut_sq(1,s)) then
           f2 = lj_force_9_6(d2, r_sq2, walls_colloid_lj% epsilon(1,s), walls_colloid_lj% sigma(1,s))
           e = e + lj_energy_9_6(r_sq2, walls_colloid_lj% epsilon(1,s), walls_colloid_lj% sigma(1,s))
        end if
        colloids% force(:,k) = colloids% force(:,k) - f1 - f2
     end do

  end function colloid_wall_interaction 

  subroutine mpcd_stream_zwall_light(particles, cells, dt,g)
    !solvent%time_stream%tic()
    type(particle_system_t), intent(inout) :: particles
    type(cell_system_t), intent(in) :: cells
    double precision, intent(in) :: dt
    double precision, dimension(3), intent(in):: g

    integer :: i
    double precision :: pos_min(3), pos_max(3), delta
    double precision, dimension(3) :: old_pos, old_vel
    double precision :: t_c
    double precision :: time

    pos_min = 0
    pos_max = cells% edges

    do i = 1, particles% Nmax
       old_pos = particles% pos(:,i) 
       old_vel = particles% vel(:,i)
       particles% pos(:,i) = particles% pos(:,i) + dt * particles% vel(:,i) + dt**2 * (particles% force(:,i) + g)/ 2
       !particles% pos(2,i) = modulo( particles% pos(2,i) , cells% edges(2) )
       !particles% pos(1,i) = modulo( particles% pos(1,i) , cells% edges(1) )
       if (cells% has_walls) then
          if (particles% pos(3,i) < pos_min(3)) then
             t_c = abs(old_pos(3)/old_vel(3))
             particles% vel(:,i) = -(old_vel + g*t_c) + g*(dt-t_c)
             particles% pos(:,i) = old_pos + old_vel*t_c + g*t_c**2/2 - (old_vel + g*t_c)*(dt-t_c)+(dt-t_c)**2*g/2
             particles% wall_flag(i) = 1
          else if (particles% pos(3,i) > pos_max(3)) then
             t_c = abs((pos_max(3)-old_pos(3))/old_vel(3))
             particles% vel(:,i) = -(old_vel + g*t_c) + g*(dt-t_c)
             particles% pos(:,i) = old_pos + old_vel*t_c + g*t_c**2/2 - (old_vel + g*t_c)*(dt-t_c)+(dt-t_c)**2*g/2
             particles% wall_flag(i) = 1
          end if
       !else
          !particles% pos(3,i) = modulo( particles% pos(3,i) , cells% edges(3) )
       end if 
    end do
    !solvent%time_stream%tac()
  end subroutine mpcd_stream_zwall_light
  
  subroutine md_vel_flow_partial(particles, edges, dt, ext_force)
    !solvent%time_stream%tic()
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: edges(3)
    double precision, intent(in) :: dt
    double precision, intent(in) :: ext_force(3)

    
    integer :: k

    

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
    !solvent%time_stream%tac()
  end subroutine md_vel_flow_partial

  subroutine buffer_particles(particles,edges, bufferlength)
     type(particle_system_t), intent(inout) :: particles
     double precision, intent(in) :: edges(3)
     integer, intent(in) :: bufferlength
  
     integer :: k  

     do k = 1, particles% Nmax
        if (particles% pos(1,k) < bufferlength) then
           if (particles% pos(2,k) < edges(2)/2.d0) then
              particles% species(k) = 1
           else
              particles% species(k) = 2
           end if  
        end if 
     end do
  end subroutine buffer_particles
end program setup_single_dimer
