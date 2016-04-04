module md
  use particle_system
  use interaction
  use common
  implicit none

  private

  public :: md_pos
  public :: apply_pbc
  public :: md_vel
  public :: rattle_dimer_pos
  public :: rattle_dimer_vel
  public :: rattle_body_pos, rattle_body_vel
  public :: lj93_zwall

contains

  subroutine md_pos(particles, dt)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: dt

    double precision :: dt_sq
    integer :: k

    dt_sq = dt**2/2

    call particles%time_md_pos%tic()
    !$omp parallel do
    do k = 1, particles% Nmax
       particles% pos(:,k) = particles% pos(:,k) + dt * particles% vel(:,k) + dt_sq * particles% force(:,k)
    end do
    call particles%time_md_pos%tac()

  end subroutine md_pos

  subroutine apply_pbc(particles, edges)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: edges(3)

    integer :: k, jump(3)

    !$omp parallel do private(jump)
    do k = 1, particles% Nmax
       jump = floor(particles% pos(:,k) / edges)
       particles% image(:,k) = particles% image(:,k) + jump
       particles% pos(:,k) = particles% pos(:,k) - jump*edges
    end do

  end subroutine apply_pbc

  subroutine md_vel(particles, edges, dt)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: edges(3)
    double precision, intent(in) :: dt

    integer :: k

    call particles%time_md_vel%tic()
    !$omp parallel do
    do k = 1, particles% Nmax
       particles% vel(:,k) = particles% vel(:,k) + &
            dt * ( particles% force(:,k) + particles% force_old(:,k) ) / 2
    end do
    call particles%time_md_vel%tac()

  end subroutine md_vel

  subroutine rattle_dimer_pos(p, d, dt,edges)
    type(particle_system_t), intent(inout) :: p
    double precision, intent(in) :: d
    double precision, intent(in) :: dt
    double precision, intent(in) :: edges(3)

    double precision :: g
    double precision :: s(3) ! direction vector
    double precision :: r(3) ! old direction vector
    double precision :: rsq, ssq, rs
    double precision :: mass1, mass2, inv_mass

    r = rel_pos(p% pos_rattle(:,1),p% pos_rattle(:,2), edges)
    s = rel_pos(p% pos(:,1),p% pos(:,2), edges)
    mass1 = p%mass(p%species(1))
    mass2 = p%mass(p%species(2))
    inv_mass = 1/mass1 + 1/mass2

    rsq = dot_product(r,r)
    ssq = dot_product(s,s)
    rs = dot_product(r,s)

    g = rs - sqrt(rs**2 - rsq*(ssq-d**2))
    g = g / (dt * inv_mass * rsq)

    p% pos(:,1) = p% pos(:,1) - g*dt*r/mass1
    p% pos(:,2) = p% pos(:,2) + g*dt*r/mass2

    p% vel(:,1) = p% vel(:,1) - g*r/mass1
    p% vel(:,2) = p% vel(:,2) + g*r/mass2

  end subroutine rattle_dimer_pos

  subroutine rattle_dimer_vel(p, d, dt,edges)
    type(particle_system_t), intent(inout) :: p
    double precision, intent(in) :: d
    double precision, intent(in) :: dt
    double precision, intent(in) :: edges(3)

    double precision :: k !second correction factor
    double precision :: s(3) !direction vector
    double precision :: mass1, mass2, inv_mass

    mass1 = p%mass(p%species(1))
    mass2 = p%mass(p%species(2))
    inv_mass = 1/mass1 + 1/mass2

    s = rel_pos(p% pos(:,1), p% pos(:,2), edges)

    k = dot_product(p%vel(:,1)-p%vel(:,2), s) / (d**2*inv_mass)

    p% vel(:,1) = p% vel(:,1) - k*s/mass1
    p% vel(:,2) = p% vel(:,2) + k*s/mass2

  end subroutine rattle_dimer_vel

  subroutine rattle_body_pos(p, links, distances, dt, edges, precision)
    type(particle_system_t), intent(inout) :: p
    integer, intent(in) :: links(:,:)
    double precision, intent(in) :: distances(:)
    double precision, intent(in) :: dt, edges(3), precision

    double precision :: g, d, error
    double precision :: s(3) ! direction vector
    double precision :: r(3) ! old direction vector
    double precision :: rsq, ssq, rs
    double precision :: mass1, mass2, inv_mass

    integer :: rattle_i, rattle_max, i_link, n_link
    integer :: i1, i2

    n_link = size(links, dim=2)
    rattle_max = 1000

    rattle_loop: do rattle_i = 1, rattle_max
       error = 0
       do i_link = 1, n_link
          i1 = links(1,i_link)
          i2 = links(2,i_link)
          d = distances(i_link)

          r = rel_pos(p% pos_rattle(:,i1),p% pos_rattle(:,i2), edges)
          s = rel_pos(p% pos(:,i1),p% pos(:,i2), edges)
          mass1 = p%mass(p%species(i1))
          mass2 = p%mass(p%species(i2))
          inv_mass = 1/mass1 + 1/mass2

          rsq = dot_product(r,r)
          ssq = dot_product(s,s)
          rs = dot_product(r,s)

          g = rs - sqrt(rs**2 - rsq*(ssq-d**2))
          g = g / (dt * inv_mass * rsq)

          p% pos(:,i1) = p% pos(:,i1) - g*dt*r/mass1
          p% pos(:,i2) = p% pos(:,i2) + g*dt*r/mass2

          p% vel(:,i1) = p% vel(:,i1) - g*r/mass1
          p% vel(:,i2) = p% vel(:,i2) + g*r/mass2

          g = sqrt(dot_product(r,r)) - d
          if (d > error) error = d
       end do
       if (error < precision) exit rattle_loop

    end do rattle_loop

    if (rattle_i==rattle_max) write(*,*) 'rattle_max reached in rattle_body_pos'

  end subroutine rattle_body_pos

  subroutine rattle_body_vel(p, links, distances, dt, edges, precision)
    type(particle_system_t), intent(inout) :: p
    integer, intent(in) :: links(:,:)
    double precision, intent(in) :: distances(:)
    double precision, intent(in) :: dt, edges(3), precision

    double precision :: g, d, error
    double precision :: s(3), k
    double precision :: mass1, mass2, inv_mass

    integer :: rattle_i, rattle_max, i_link, n_link
    integer :: i1, i2

    n_link = size(links, dim=2)
    rattle_max = 1000

    rattle_loop: do rattle_i = 1, rattle_max
       error = 0
       do i_link = 1, n_link
          i1 = links(1,i_link)
          i2 = links(2,i_link)
          d = distances(i_link)
          mass1 = p%mass(p%species(i1))
          mass2 = p%mass(p%species(i2))
          inv_mass = 1/mass1 + 1/mass2

          s = rel_pos(p% pos(:,i1), p% pos(:,i2), edges)

          k = dot_product(p%vel(:,i1)-p%vel(:,i2), s) / (d**2*inv_mass)

          p% vel(:,i1) = p% vel(:,i1) - k*s/mass1
          p% vel(:,i2) = p% vel(:,i2) + k*s/mass2

          k = dot_product(p%vel(:,i1)-p%vel(:,i2), s) / (d**2*inv_mass)
          if (k>error) error = k
       end do
       if (error < precision) exit rattle_loop
    end do rattle_loop

    if (rattle_i==rattle_max) write(*,*) 'rattle_max reached in rattle_body_vel'

  end subroutine rattle_body_vel

  function lj93_zwall(particles, edges, lj_params) result(e)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: edges(3)
    type(lj_params_t), intent(in) :: lj_params
    double precision :: e

    integer :: i, s
    double precision :: z, z_sq, f, dir, shift

    
    e = 0
    do i = 1, particles%Nmax
       s = particles%species(i)
       if (s<=0) continue
       z = particles%pos(3,i)
       if (z > edges(3)/2) then
          z = edges(3) - z - lj_params% shift
          dir = -1
       else
          dir = 1 
          z = z - lj_params% shift
       end if
       z_sq = z**2
       if (z_sq <= lj_params% cut_sq(1,s)) then
         f = lj_force_9_3(z, z_sq, lj_params%epsilon(1,s), lj_params%sigma(1,s))
         particles%force(3,i) = particles%force(3,i) + dir*f
         e = e + lj_energy_9_3(z_sq, lj_params%epsilon(1,s), lj_params%sigma(1,s))
       end if
    end do

  end function lj93_zwall

end module md
