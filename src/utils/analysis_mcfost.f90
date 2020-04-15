!--------------------------------------------------------------------------!
! The Phantom Smoothed Particle Hydrodynamics code, by Daniel Price et al. !
! Copyright (c) 2007-2020 The Authors (see AUTHORS)                        !
! See LICENCE file for usage and distribution conditions                   !
! http://phantomsph.bitbucket.io/                                          !
!--------------------------------------------------------------------------!
!+
!  MODULE: analysis
!
!  DESCRIPTION:
!   Analysis routine to call MCFOST code to perform post-processing
!   radiation transport
!
!  REFERENCES: None
!
!  OWNER: Sergei Biriukov
!
!  $Id$
!
!  RUNTIME PARAMETERS: None
!
!  DEPENDENCIES: densityforce, dim, eos, growth, initial_params, io,
!    linklist, mcfost2phantom, omp_lib, options, part, physcon, timestep,
!    units
!+
!--------------------------------------------------------------------------
module analysis
 use omp_lib

 implicit none
 character(len=20), parameter, public :: analysistype = 'mcfost'
 public :: do_analysis

 private

contains

subroutine do_analysis(dumpfile,num,xyzh,vxyzu,particlemass,npart,time,iunit)
 use mcfost2phantom, only:init_mcfost_phantom,&
                          run_mcfost_phantom,&
                          diffusion_opacity,&
                          deinit_mcfost_phantom
 use part,           only:massoftype,iphase,dustfrac,hfact,npartoftype,&
                          get_ntypes,iamtype,maxphase,maxp,idust,nptmass,&
                          massoftype,xyzmh_ptmass,vxyz_ptmass,luminosity,igas,&
                          grainsize,graindens,ndusttypes
 !   rhoh,inumph,ivorcl, &
 !   do_radiation,radiation,ithick,maxirad,ikappa,iradxi,idflux, &
! use units,          only:unit_velocity,unit_energ
! use io,             only:warning,iprint
 use units,          only:umass,utime,udist
 use io,             only:fatal
 use dim,            only:use_dust,lightcurve,maxdusttypes,use_dustgrowth
 use eos,            only:temperature_coef,gmw,gamma
 use timestep,       only:dtmax
 use options,        only:use_dustfrac,use_mcfost,use_Voronoi_limits_file,Voronoi_limits_file, &
                          use_mcfost_stellar_parameters
 use physcon,        only:cm,gram,c,steboltz

 character(len=*), intent(in)    :: dumpfile
 integer,          intent(in)    :: num,npart,iunit
 real,             intent(in)    :: xyzh(:,:)
 real,             intent(in)    :: particlemass,time
 real,             intent(inout) :: vxyzu(:,:)

 logical, save   :: init_mcfost = .false., isinitial = .true.
 real            :: mu_gas,factor,T_to_u
 real(kind=4)    :: Tdust(npart),n_packets(npart)
 integer         :: ierr,ntypes,dustfluidtype,ilen,nlum,i
 integer(kind=1) :: itype(maxp)
 logical         :: compute_Frad
 real(kind=8), dimension(6), save            :: SPH_limits
 real,         dimension(:),     allocatable :: dudt
 real,    parameter :: Tdefault = 1.
 logical, parameter :: write_T_files = .false. ! ask mcfost to write fits files with temperature structure
 integer, parameter :: ISM = 2 ! ISM heating : 0 -> no ISM radiation field, 1 -> ProDiMo, 2 -> Bate & Keto
 character(len=len(dumpfile) + 20) :: mcfost_para_filename
 real :: a_code,c_code,rhoi,steboltz_code,pmassi,Tmin,Tmax,default_kappa,kappa_diffusion
 integer :: omp_threads

 omp_threads = omp_get_max_threads()
 ! call omp_set_dynamic(.false.)
! call omp_set_num_threads(1)

 if (use_mcfost .and. use_dustgrowth) then
    write(*,*) "Converting to fake multi large grains"
    call growth_to_fake_multi(npart)
 endif

 if (use_mcfost) then
    if (.not.init_mcfost) then
       ilen = index(dumpfile,'_',back=.true.) ! last position of the '_' character
       mcfost_para_filename = dumpfile(1:ilen-1)//'.para'
       call init_mcfost_phantom(mcfost_para_filename,ndusttypes,use_Voronoi_limits_file,&
          Voronoi_limits_file,SPH_limits,ierr, &
          fix_star = use_mcfost_stellar_parameters)
       if (ierr /= 0) call fatal('mcfost-phantom','error in init_mcfost_phantom')
       init_mcfost = .true.
    endif

    ntypes = get_ntypes(npartoftype)
    if (maxphase==maxp) then
       itype = iamtype(iphase)
    else
       itype(:) = 1
    endif
    if (.not. use_dust) then
       ndusttypes = 0
    endif
    if (use_dustfrac) then
       dustfluidtype = 1
    else
       dustfluidtype = 2
    endif

    nlum = npart
    allocate(dudt(nlum))
    if (lightcurve) then
       dudt(1:nlum) = luminosity(1:nlum)
    else
       dudt(1:nlum) = vxyzu(4,1:nlum) * massoftype(igas) / dtmax
    endif

    factor = 1.0/(temperature_coef*gmw*(gamma-1))
    ! this this the factor needed to compute u^(n+1)/dtmax from temperature
    T_to_u = factor * massoftype(igas) /dtmax

    !  Call to mcfost on phantom-radiation branch
    !  call run_mcfost_phantom(&
    !    npart,nptmass,ntypes,ndusttypes,dustfluidtype,npartoftype,maxirad,&
    !    xyzh,vxyzu,radiation,ivorcl,&
    !    itype,grainsize,graindens,dustfrac,massoftype,&
    !    xyzmh_ptmass,hfact,umass,utime,udist,nlum,dudt,compute_Frad,SPH_limits,Tdust,&
    !    n_packets,mu_gas,ierr,write_T_files,ISM,T_to_u)

    call run_mcfost_phantom(npart,nptmass,ntypes,ndusttypes,dustfluidtype,&
         npartoftype,xyzh,vxyzu,itype,grainsize,graindens,dustfrac,massoftype,&
         xyzmh_ptmass,vxyz_ptmass,hfact,umass,utime,udist,nlum,dudt,compute_Frad,SPH_limits,Tdust,&
         Frad,n_packets,mu_gas,ierr,write_T_files,ISM,T_to_u)
    !print*,' mu_gas = ',mu_gas

    Tmin = minval(Tdust, mask=(Tdust > 0.))
    Tmax = maxval(Tdust)
    ! (176-17)*0.25
    if (use_mcfost .and. use_dustgrowth) then
       write(*,*) "Converting back to normal"
       call back_to_growth(npart)
    endif

    write(*,*) ''
    write(*,*) 'Minimum temperature = ', Tmin
    write(*,*) 'Maximum temperature = ', Tmax
    write(*,*) ''

    c_code        = c/unit_velocity
    steboltz_code = steboltz/(unit_energ/(udist**2*utime))
    a_code        = 4.*steboltz_code/c_code
    pmassi        = massoftype(igas)
    ! set thermal energy

    if (do_radiation) then
       radiation(inumph,:) = 0.
       if (isinitial) then
          default_kappa = 0.5
       else
          default_kappa = 0.5*(maxval(radiation(ikappa,:))+minval(radiation(ikappa,:)))&
            *(udist**2/umass)
       endif
       write(iprint,"(/,a,f4.2,' cm^2/g')") &
          ' -}+{- RADIATION: cutoff particles kappa = ',&
          default_kappa
       do i=1,npart
          if (maxphase==maxp) then
             if (iamtype(iphase(i)) /= igas) cycle
          endif
          radiation(inumph,i) = n_packets(i)
          if (radiation(inumph,i) > 1e2) then
             radiation(ithick,i) = 0.
          else
             radiation(ithick,i) = 1.
          endif
          if (isinitial.or.(radiation(ithick,i) < 0.5)) then
             ! initial run (t == 0) OR it has got enough info from mcfost
             ! => set new temperature for gas and radiation
             if (Tdust(i) > 1.) then
                vxyzu(4,i) = Tdust(i)*factor
                ! if the temperature is correct and set by mcfost
                ! => suppose we are at equilibrium
                rhoi = rhoh(xyzh(4,i),pmassi)
                radiation(iradxi,i) = a_code*Tdust(i)**4.0/rhoi
                radiation(idflux,i) = 0
             else
                ! if I got no temperature from mcfost
                ! => lets try to handle the particle by SPH
                if (isinitial) then
                   vxyzu(4,i) = ((Tmax-Tmin)*0.2)*factor
                   rhoi = rhoh(xyzh(4,i),pmassi)
                   radiation(iradxi,i) = a_code*((Tmax-Tmin)*0.2)**4.0/rhoi
                   radiation(idflux,i) = 0
                else
                   radiation(ithick,i) = 1.
                endif
             endif
             ! else
             ! it is not initial run AND the particle has not got info from mcfost
             ! => temperature is old because of diffusion
          endif
          ! no matter what happend on previous stage, we need to set new
          ! diffusion coefficien with regards to a new/old temperatures
          if (radiation(ivorcl,i) > 0) then
             call diffusion_opacity(vxyzu(4,i)/factor,int(radiation(ivorcl,i)),kappa_diffusion)
             radiation(ikappa,i) = kappa_diffusion*(cm**2/gram)/(udist**2/umass)
          else
             radiation(ikappa,i) = default_kappa*(cm**2/gram)/(udist**2/umass)
          endif
       enddo
    else
       do i=1,npart
          if (Tdust(i) > 1.) then
             vxyzu(4,i) = Tdust(i) * factor
          else
             ! if mcfost doesn't return a temperature set it to Tdefault
             vxyzu(4,i) = Tdefault * factor
          endif
       enddo
    endif

    if (allocated(dudt)) deallocate(dudt)

    call omp_set_num_threads(omp_threads)
    ! call omp_set_dynamic(.true.)
    call deinit_mcfost_phantom()
    isinitial = .false.

    write(iprint,"(/,a,f6.2,'%')") &
          ' -}+{- RADIATION particles done by SPH = ',&
          100.*count(radiation(ithick,:)==1)/real(size(radiation(ithick,:)))

    write(*,*) "End of analysis mcfost"
 endif ! use_mcfost

 return

end subroutine do_analysis

subroutine growth_to_fake_multi(npart)
 use part,         only:xyzh,vxyzu,divcurlv,divcurlB,Bevol,&
                        fxyzu,fext,alphaind,gradh
 use growth,       only:bin_to_multi,f_smax,size_max,b_per_dex
 use linklist,     only:set_linklist
 use densityforce, only:densityiterate
 integer, intent(in)  :: npart
 real                 :: stressmax = 0.

 !- bin sizes
 call bin_to_multi(b_per_dex,f_smax,size_max,verbose=.false.)

 !- get neighbours
 call set_linklist(npart,npart,xyzh,vxyzu)

 !- get new density
 call densityiterate(1,npart,npart,xyzh,vxyzu,divcurlv,divcurlB,Bevol,stressmax,&
                          fxyzu,fext,alphaind,gradh)

end subroutine growth_to_fake_multi

subroutine back_to_growth(npart)
 use part,           only: ndusttypes,ndustlarge,idust,massoftype,&
                           npartoftype,iamtype,iphase,idust,&
                           set_particle_type
 use initial_params, only:mdust_in
 integer, intent(in)    :: npart
 integer                :: i,j,ndustold,itype


 ndustold = sum(npartoftype(idust:))
 do i=1,npart
    itype = iamtype(iphase(i))
    if (itype > idust) then
       npartoftype(idust) = npartoftype(idust) + 1
       npartoftype(itype) = npartoftype(itype) - 1
       call set_particle_type(i,idust)
    endif
 enddo

 do j=2,ndusttypes
    if (npartoftype(idust+j-1) /= 0) write(*,*) 'ERROR! npartoftype ",idust+j-1 " /= 0'
    massoftype(idust+j-1)      = 0.
    mdust_in(idust+j-1)        = 0.
 enddo

 ndusttypes                    = 1
 ndustlarge                    = 1
 mdust_in(idust)               = npartoftype(idust)*massoftype(idust)

 !- sanity checks for npartoftype
 if (npartoftype(idust) /= ndustold) then
    write(*,*) 'ERROR! npartoftype not conserved'
    write(*,*) npartoftype(idust), " <-- new vs. old --> ",ndustold
 endif

end subroutine back_to_growth

end module
