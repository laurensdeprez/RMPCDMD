module md
  use particle_system
  use common
  implicit none

  private

  public :: md_pos
  public :: md_pos_flow
  public :: apply_pbc
  public :: md_vel
  public :: md_vel_flow
  public :: rattle_dimer_pos
  public :: rattle_dimer_vel

contains

  subroutine md_pos(particles, dt)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: dt

    integer :: k

    !$omp parallel do
    do k = 1, particles% Nmax
       particles% pos(:,k) = particles% pos(:,k) + dt * particles% vel(:,k) + dt**2 * particles% force(:,k) / 2
    end do

  end subroutine md_pos

  subroutine md_pos_flow(particles, dt, ext_force)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: dt
    double precision, intent(in) :: ext_force(3)

    integer :: k

    !$omp parallel do
    do k = 1, particles% Nmax
       particles% pos(:,k) = particles% pos(:,k) + dt * particles% vel(:,k) + dt**2 * (particles% force(:,k) + ext_force(:))/ 2
    end do

  end subroutine md_pos_flow

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

    !$omp parallel do
    do k = 1, particles% Nmax
       particles% vel(:,k) = particles% vel(:,k) + &
            dt * ( particles% force(:,k) + particles% force_old(:,k) ) / 2 
    end do

  end subroutine md_vel

  subroutine md_vel_flow(particles, edges, dt,ext_force)
    type(particle_system_t), intent(inout) :: particles
    double precision, intent(in) :: edges(3)
    double precision, intent(in) :: dt
    double precision, intent(in) :: ext_force(3)

    integer :: k

    !$omp parallel do
    do k = 1, particles% Nmax
       particles% vel(:,k) = particles% vel(:,k) + &
            dt * ( particles% force(:,k) + particles% force_old(:,k) ) / 2 &
            + dt*ext_force(:)
    end do

  end subroutine md_vel_flow

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

end module md
