function varargout = inverseKinBackend(obj,mode,t,q_seed,q_nom,varargin)
% inverseKin(obj,mode,q_seed,q_nom,t,constraint1,constraint2,...,options)
% Two modes,
% mode 1 -- solve IK 
%   min_q (q-q_nom'*Q*(q-q_nom)
%   subject to
%          constraint1 at t
%          constraint2 at t
%   .....
%   using q_seed as the initial guess
%   If t = [], then all kc are ative.
%   If t is a scalar, then solve IK for that single time only
%   If t is an array, then for each time, solve an IK
% 
% mode 2 -- solve IK for a sequence of time
%   min_qi sum_i qdd_i'*Qa*qdd_i+qd_i'*Qv*qd_i+(q_i-q_nom(:,i))'*Q*(q_i-_nom(:,i)) 
%   subject to 
%          constraint_j at t_i
%   qd,qdd are computed by supposing q is a cubic spline.
% @param q_seed       The seed guess, a matrix, wich column i representing the
%                     seed at t[i]
% @param q_nom        The nominal posture, a matrix, with column i representing
%                     The nominal posture at t[i]
% @param constraint   A Constraint class object, accept KinematicConstraint,
%                     QuasiStaticConstraint and PostureConstraint currently
% @param ikoptions    An IKoptions object, please refer to IKoptions for detail

% note: keeping typecheck/sizecheck to a minimum because this might have to
% run inside a dynamical system (so should be fast)
global SNOPT_USERFUN;
nq = obj.getNumDOF();
if(isempty(t))
  nT = 1;
else
  nT = length(t);
end
if(~isa(varargin{end},'IKoptions'))
  varargin{end+1} = IKoptions(obj);
end
ikoptions = varargin{end};
use_mex = ikoptions.use_mex;
if(~use_mex)
%   qsc = QuasiStaticConstraint(obj);
  qsc = QuasiStaticConstraint(obj);
  qsc = qsc.setActive(false);
  [joint_min,joint_max] = obj.getJointLimits();
  joint_min = bsxfun(@times,joint_min,ones(1,nT));
  joint_max = bsxfun(@times,joint_max,ones(1,nT));
end
for i = 1:nT
  if(isempty(t))
    ti = [];
  else
    ti = t(i);
  end
end
constraint_ptr_cell = cell(1,length(varargin)-1);
st_kc_cell = cell(1,length(varargin)-1); % SingleTimeKinematicConstraint
mt_kc_cell = cell(1,length(varargin)-1); % MultipleTimeKinematicConstraint
num_st_kc = 0;
num_mt_kc = 0;
for j = 1:length(varargin)-1
  if(isa(varargin{j},'Constraint'))
    constraint_ptr_cell{j} = varargin{j}.mex_ptr;
    if(~use_mex)
      if(isa(varargin{j},'PostureConstraint'))
        for i = 1:nT
          [lb,ub] = varargin{j}.bounds(ti);
          joint_min(:,i) = max([joint_min(:,i) lb],[],2);
          joint_max(:,i) = min([joint_max(:,i) ub],[],2);
          if(any(joint_min(:,i)>joint_max(:,i)))
            error('Joint maximum should be no smaller than joint minimum, check if the joint limits are consistent');
          end
        end
      elseif(isa(varargin{j},'SingleTimeKinematicConstraint'))
        num_st_kc = num_st_kc+1;
        st_kc_cell{num_st_kc} = varargin{j};
      elseif(isa(varargin{j},'MultipleTimeKinematicConstraint'))
        num_mt_kc = num_mt_kc+1;
        mt_kc_cell{num_mt_kc} = varargin{j};
      elseif(isa(varargin{j},'QuasiStaticConstraint'))
        qsc = varargin{j};
      end
    end
  elseif(isa(varargin{j},'DrakeConstraintMexPointer'))
    constraint_ptr_cell{j} = varargin{j};
    use_mex = true;  
  end
end
if(use_mex)
  varargout = inverseKinBackendmex(obj.mex_model_ptr,mode,t,q_seed,q_nom,constraint_ptr_cell{:},ikoptions);
else
  st_kc_cell = st_kc_cell(1:num_st_kc);
  mt_kc_cell = mt_kc_cell(1:num_mt_kc);
  Q = ikoptions.Q;
  debug_mode = ikoptions.debug_mode;
  if(isempty(qsc))
    qscActiveFlag = false;
  else
    qscActiveFlag = qsc.active;
  end
  sizecheck(q_seed,[nq,nT]);
  sizecheck(q_nom,[nq,nT]);
  q = zeros(nq,nT);
  iCfun_cell = cell(1,nT);
  jCvar_cell = cell(1,nT);
  nc_array = zeros(1,nT); % the number of constraint in each knot
  nG_array = zeros(1,nT); % the number of G in each knot
  nA_array = zeros(1,nT); % the number of A in each knot
  A_cell = cell(1,nT);
  iAfun_cell = cell(1,nT);
  jAvar_cell = cell(1,nT);
  Cmin_cell = cell(1,nT);
  Cmax_cell = cell(1,nT);
  Cname_cell = cell(1,nT);
  infeasible_constraint = {};
  if(mode == 1)
    info = zeros(1,nT);
  elseif(mode == 2)
    info = 0;
  end
  for i = 1:nT
    if(isempty(t))
      ti = [];
    else
      ti = t(i);
    end
    for j = 1:length(st_kc_cell)
      kc = st_kc_cell{j};
      [lb,ub] = kc.bounds(ti);
      Cmin_cell{i} = [Cmin_cell{i};lb];
      Cmax_cell{i} = [Cmax_cell{i};ub];
      nc = kc.getNumConstraint(ti);
      iCfun_cell{i} = [iCfun_cell{i};nc_array(i)+reshape(bsxfun(@times,(1:nc)',ones(1,nq)),[],1)];
      jCvar_cell{i} = [jCvar_cell{i};reshape(bsxfun(@times,(1:nq),ones(nc,1)),[],1)];
      nc_array(i) = nc_array(i)+nc;
      nG_array(i) = nG_array(i)+nc*nq;
      if(debug_mode)
        Cname_cell{i} = [Cname_cell{i};kc.name(ti)];
      end
    end
    if(qscActiveFlag)
      num_qsc_cnst = qsc.getNumConstraint(ti);
      iCfun_cell{i} = [iCfun_cell{i}; nc_array(i)+reshape(bsxfun(@times,(1:(num_qsc_cnst-1))',ones(1,nq+qsc.num_pts)),[],1)];
      jCvar_cell{i} = [jCvar_cell{i}; reshape(bsxfun(@times,ones(num_qsc_cnst-1,1),(1:(nq+qsc.num_pts))),[],1)];
      iAfun_cell{i} = [iAfun_cell{i}; nc_array(i)+num_qsc_cnst*ones(qsc.num_pts,1)];
      jAvar_cell{i} = [jAvar_cell{i}; nq+(1:qsc.num_pts)'];
      A_cell{i} = [A_cell{i};ones(qsc.num_pts,1)];
      [qsc_lb,qsc_ub] = qsc.bounds(ti);
      Cmin_cell{i} = [Cmin_cell{i};[qsc_lb;1]];
      Cmax_cell{i} = [Cmax_cell{i};[qsc_ub;1]];
      nc_array(i) = nc_array(i)+num_qsc_cnst;
      nG_array(i) = nG_array(i)+(num_qsc_cnst-1)*(nq+qsc.num_pts);
      nA_array(i) = nA_array(i)+qsc.num_pts;
      if(debug_mode)
        Cname_cell{i} = [Cname_cell{i};qsc.name(ti);{sprintf('quasi static constraint weights at time %10.4f',ti)}];
      end
    end
    if(mode == 1)
      wmin = joint_min;
      wmax = joint_max;
      if(~ikoptions.sequentialSeedFlag)
        x0 = q_seed(:,i);
      else
        if(i == 1)
          x0 = q_seed(:,i);
        else
          if(info(i-1)>10)
            x0 = q_seed(:,i);
          else
            x0 = q(:,i-1);
          end
        end
      end
      if(qscActiveFlag)
        wmin = [wmin;zeros(qsc.num_pts,nT)];
        wmax = [wmax;ones(qsc.num_pts,nT)];
        x0 = [x0; 1/qsc.num_pts*ones(qsc.num_pts,1)];
      end
      if(any(wmin>wmax))
        error('Drake:inverseKinBackend: The lower bound of the decision variable is larger than the upper bound, possibly check the conflicting posture constraint');
      end
      SNOPT_USERFUN = @(w) IK_userfun(obj,w,ti,st_kc_cell,q_nom(:,i),Q,nq,nc_array(i),nG_array(i),qsc);
      snseti('Major iterations limit',ikoptions.SNOPT_MajorIterationsLimit);
      snseti('Iterations limit',ikoptions.SNOPT_IterationsLimit);
      snseti('Superbasics limit',ikoptions.SNOPT_SuperbasicsLimit);
      snsetr('Major optimality tolerance',ikoptions.SNOPT_MajorOptimalityTolerance);
      snsetr('Major feasibility tolerance',ikoptions.SNOPT_MajorFeasibilityTolerance);
      A = A_cell{i};
      iAfun = iAfun_cell{i}+1;
      jAvar = jAvar_cell{i};
      iGfun = [ones(nq,1);iCfun_cell{i}+1];
      jGvar = [(1:nq)';jCvar_cell{i}];
      Fmin = [0;Cmin_cell{i}];
      Fmax = [inf;Cmax_cell{i}];
      [x_sol,F,info(i)] = snopt(x0,wmin(:,i),wmax(:,i),Fmin,Fmax,'snoptUserfun',0,1,A,iAfun,jAvar,iGfun,jGvar);
      q(:,i) = x_sol(1:nq);
      if(debug_mode)
        Fname = [{'objective'};Cname_cell{i}];
      end
      
      if(info == 13)
        ub_err = F-Fmax;
        max_ub_error = max(ub_err);
        max_ub_error = max_ub_error*(max_ub_error>0);
        lb_err = Fmin-F;
        max_lb_error = max(lb_err);
        max_lb_error = max_lb_error*(max_lb_error>0);
        if(max_ub_error+max_lb_error>1e-4)
            info = 13;
            infeasible_constraint_idx = (ub_err>5e-5)|(lb_err>5e-5);
            if(debug_mode)
              infeasible_constraint = [infeasible_constraint Fname(infeasible_constraint_idx)];
            end
        else
            info = 4;
        end
      end
    end
  end
  if(mode == 1)
    varargout{1} = q;
    varargout{2} = info;
    if(nargout == 3)
      varargout{3} = infeasible_constraint;
    end
  end
  if(mode == 2)
    Qa = ikoptions.Qa;
    Qv = ikoptions.Qv;
    dt = diff(t);
    dt_ratio = dt(1:end-1)./dt(2:end);
    q0 = ikoptions.q0;
    qdot0 = ikoptions.qd0;
    nSample = nT-1;
    % Suppose the joint angles are interpolated using cubic splines, then the
    velocity_mat1_diag1 = reshape([ones(nq,1) repmat(dt(1:end-1).*(2+2*dt_ratio),nq,1) ones(nq,1)],[],1);
    velocity_mat1_diag2 = reshape([zeros(nq,1) repmat(dt(1:end-1).*dt_ratio,nq,1)],[],1);
    velocity_mat1_diag3 = [reshape(repmat(dt(1:end-1),nq,1),[],1);zeros(nq,1)];
    velocity_mat1 = sparse((1:nq*(nSample+1))',(1:nq*(nSample+1))',velocity_mat1_diag1)...
        +sparse((1:nq*(nSample))',nq+(1:nq*nSample)',velocity_mat1_diag2,nq*(nSample+1),nq*(nSample+1))...
        +sparse(nq+(1:nq*nSample)',(1:nq*nSample)',velocity_mat1_diag3,nq*(nSample+1),nq*(nSample+1));


    velocity_mat2_diag1 = reshape([zeros(nq,1) bsxfun(@times,3*ones(1,nSample-1)-3*dt_ratio.^2,ones(nq,1)) zeros(nq,1)],[],1);
    velocity_mat2_diag2 = reshape([zeros(nq,1) bsxfun(@times,3*dt_ratio.^2,ones(nq,1))],[],1);
    velocity_mat2_diag3 = [-3*ones(nq*(nSample-1),1);zeros(nq,1)];
    velocity_mat2 = sparse((1:nq*(nSample+1))',(1:nq*(nSample+1))',velocity_mat2_diag1)...
        +sparse((1:nq*nSample)',nq+(1:nq*nSample)',velocity_mat2_diag2,nq*(nSample+1),nq*(nSample+1))...
        +sparse(nq+(1:nq*nSample)',(1:nq*nSample)',velocity_mat2_diag3,nq*(1+nSample),nq*(1+nSample));
    velocity_mat = velocity_mat1\velocity_mat2;
    velocity_mat = velocity_mat(nq+1:end-nq,:);

    % [qddot(0);...qddot(k)] =
    % accel_mat*[q(0);...;q(k)]+accel_mat_qdot0*qdot(0)+accel_mat_qdof*qdot(k)
    accel_mat1_diag1 = reshape(bsxfun(@times,[-6./(dt.^2) -6/(dt(end)^2)],ones(nq,1)),[],1);
    accel_mat1_diag2 = reshape(bsxfun(@times,6./(dt.^2),ones(nq,1)),[],1);
    accel_mat1_diag3 = 6/(dt(end)^2)*ones(nq,1);
    accel_mat1 = sparse((1:nq*(nSample+1))',(1:nq*(nSample+1))',accel_mat1_diag1)...
        +sparse((1:nq*nSample)',nq+(1:nq*nSample)',accel_mat1_diag2,nq*(nSample+1),nq*(nSample+1))...
        +sparse(nq*nSample+(1:nq)',nq*(nSample-1)+(1:nq)',accel_mat1_diag3,nq*(nSample+1),nq*(nSample+1));
    accel_mat2_diag1 = reshape(bsxfun(@times,[-4./dt 5/dt(end)],ones(nq,1)),[],1);
    accel_mat2_diag2 = reshape(bsxfun(@times,-2./dt,ones(nq,1)),[],1);
    accel_mat2_diag3 = 4/dt(end)*ones(nq,1);
    accel_mat2 = sparse((1:nq*(nSample+1))',(1:nq*(nSample+1))',accel_mat2_diag1)...
        +sparse((1:nq*nSample)',nq+(1:nq*nSample)',accel_mat2_diag2,nq*(nSample+1),nq*(nSample+1))...
        +sparse(nq*nSample+(1:nq)',nq*(nSample-1)+(1:nq)',accel_mat2_diag3,nq*(nSample+1),nq*(nSample+1));
    accel_mat = accel_mat1+accel_mat2(:,nq+1:end-nq)*velocity_mat;
    accel_mat_qd0 = accel_mat2(:,1:nq);
    accel_mat_qdf = accel_mat2(:,end-nq+1:end);
    
    if(qscActiveFlag)
      wmin = [reshape([joint_min(:,2:end);zeros(qsc.num_pts,nT-1)],[],1);ikoptions.qdf_lb];
      wmax = [reshape([joint_max(:,2:end);ones(qsc.num_pts,nT-1)],[],1);ikoptions.qdf_ub];
    else
      wmin = [reshape(joint_min(:,2:end),[],1);ikoptions.qdf_lb];
      wmax = [reshape(joint_max(:,2:end),[],1);ikoptions.qdf_ub];
    end
    % parse the MultipleTimeKinematicConstraint
    
    nF_total = sum(nc_array(2:end))+1;
    nG_total = sum(nG_array(2:end))+nq*nT;
    nA_total = sum(nA_array(2:end));
    Fmin = zeros(nF_total,1);
    Fmax = zeros(nF_total,1);
    if(debug_mode)
      Fname = cell(nF_total,1);
      Fname{1} = 'objective';
    end
    iGfun = zeros(nG_total,1);
    jGvar = zeros(nG_total,1);
    iAfun = zeros(nA_total,1);
    jAvar = zeros(nA_total,1);
    A = zeros(nA_total,1);
    Fmin(1) = -inf;
    Fmax(1) = inf;
    iGfun(1:nq*nT) = ones(nq*nT,1);
    if(qscActiveFlag)
      q_idx = reshape(bsxfun(@plus,(1:nq)',(nq+qsc.num_pts)*(0:(nT-2))),[],1);
      qsc_weights_idx = reshape(bsxfun(@plus,nq+(1:qsc.num_pts)',(nq+qsc.num_pts)*(0:(nT-2))),[],1);
      qdotf_idx = (nq+qsc.num_pts)*(nT-1)+(1:nq);
    else
      q_idx = (1:nq*(nT-1))';
      qsc_weights_idx = [];
      qdotf_idx = nq*(nT-1)+(1:nq);
    end
    jGvar(1:nq*(nT-1)) = q_idx;
    jGvar(nq*(nT-1)+(1:nq)) = qdotf_idx;
    nf_cum = 1;
    nG_cum = nq*nT;
    nA_cum = 0;
    x_start_idx = 0;
    for i = 2:nT
      Fmin(nf_cum+(1:nc_array(i))) = Cmin_cell{i};
      Fmax(nf_cum+(1:nc_array(i))) = Cmax_cell{i};
      if(debug_mode)
        Fname(nf_cum+(1:nc_array(i))) = Cname_cell{i};
      end
      iGfun(nG_cum+(1:nG_array(i))) = nf_cum+iCfun_cell{i};
      jGvar(nG_cum+(1:nG_array(i))) = x_start_idx+jCvar_cell{i};
      iAfun(nA_cum+(1:nA_array(i))) = nf_cum+iAfun_cell{i};
      jAvar(nA_cum+(1:nA_array(i))) = x_start_idx+jAvar_cell{i};
      A(nA_cum+(1:nA_array(i))) = A_cell{i};
      nf_cum = nf_cum+nc_array(i);
      nG_cum = nG_cum+nG_array(i);
      nA_cum = nA_cum+nA_array(i);
      if(qscActiveFlag)
        x_start_idx = x_start_idx+nq+qsc.num_pts;
      else
        x_start_idx = x_start_idx+nq;
      end
    end
    
    mtkc_nc = zeros(1,num_mt_kc);
    
    for j = 1:num_mt_kc
      kc = mt_kc_cell{j};
      mtkc_nc(j) = kc.getNumConstraint(t(2:end));
    end
    total_mtkc_nc = sum(mtkc_nc);
    total_mtkc_nG = total_mtkc_nc*(nq*(nT-1));
    Fmin = [Fmin;zeros(total_mtkc_nc,1)];
    Fmax = [Fmax;zeros(total_mtkc_nc,1)];
    if(debug_mode)
      Fname = [Fname;cell(total_mtkc_nc,1)];
    end
    iGfun = [iGfun;zeros(total_mtkc_nG,1)];
    jGvar = [jGvar;zeros(total_mtkc_nG,1)];
    for j = 1:num_mt_kc
      kc = mt_kc_cell{j};
      [Fmin(nf_cum+(1:mtkc_nc(j))),Fmax(nf_cum+(1:mtkc_nc(j)))] = kc.bounds(t(2:end));
      if(debug_mode)
        Fname(nf_cum+(1:mtkc_nc(j))) = kc.name(t(2:end));
      end
      iGfun(nG_cum+(1:mtkc_nc(j)*(nq*(nT-1)))) = nf_cum+reshape(bsxfun(@times,(1:mtkc_nc(j))',ones(1,length(q_idx))),[],1);
      jGvar(nG_cum+(1:mtkc_nc(j)*(nq*(nT-1)))) = reshape(bsxfun(@times,ones(mtkc_nc(j),1),q_idx),[],1);
      nf_cum = nf_cum+mtkc_nc(j);
      nG_cum = nG_cum+mtkc_nc(j)*(nq*(nT-1));
    end
    
    if(qscActiveFlag)
      w0 = [reshape([q_seed(:,2:end);1/qsc.num_pts*ones(qsc.num_pts,nT-1)],[],1);(ikoptions.qdf_ub+ikoptions.qdf_lb)/2];
    else
      w0 = [reshape(q_seed(:,2:end),[],1);(ikoptions.qdf_ub+ikoptions.qdf_lb)/2];
    end
    SNOPT_USERFUN = @(w) IKtraj_userfun(obj,w,q0,qdot0,t,st_kc_cell,mt_kc_cell,q_nom,Qa,Qv,Q,velocity_mat,accel_mat,accel_mat_qd0,accel_mat_qdf,nq,nT,nc_array,nG_array,nf_cum,nG_cum,q_idx,qsc_weights_idx,qdotf_idx,qsc);
    snseti('Major iterations limit',ikoptions.SNOPT_MajorIterationsLimit);
    snseti('Iterations limit',ikoptions.SNOPT_IterationsLimit);
    snseti('Superbasics limit',ikoptions.SNOPT_SuperbasicsLimit);
    snsetr('Major optimality tolerance',ikoptions.SNOPT_MajorOptimalityTolerance);
    snsetr('Major feasibility tolerance',ikoptions.SNOPT_MajorFeasibilityTolerance);

    [w_sol,F,info] = snopt(w0,wmin,wmax,Fmin,Fmax,'snoptUserfun',0,1,A,iAfun,jAvar,iGfun,jGvar);  
    q = w_sol(q_idx);
    qdotf = w_sol(qdotf_idx);
    qdot = [qdot0 reshape(velocity_mat*[q0;q(:)],nq,nSample-1) qdotf];
    qddot = reshape(accel_mat*[q0;q(:)]+accel_mat_qd0*qdot0+accel_mat_qdf*qdotf,nq,nT); 
    q = [q0 reshape(q,nq,nSample)];
    if(debug_mode)
      Fname = [{'objective'};Fname];
    end
    if(info == 13)
      ub_err = F-Fmax;
      max_ub_error = max(ub_err);
      max_ub_error = max_ub_error*(max_ub_error>0);
      lb_err = Fmin-F;
      max_lb_error = max(lb_err);
      max_lb_error = max_lb_error*(max_lb_error>0);
      if(max_ub_error+max_lb_error>1e-4)
        info = 13;
        infeasible_constraint_idx = (ub_err>5e-5)|(lb_err>5e-5);
        if(debug_mode)
          infeasible_constraint = Fname(infeasible_constraint_idx);
        end
      else
        info = 4;
      end
    end
    varargout{1} = q;
    varargout{2} = qdot;
    varargout{3} = qddot;
    varargout{4} = info;
    if(nargout >= 3)
      varargout{5} = infeasible_constraint;
    end
  end

end
end

function [f,G] = IK_userfun(obj,x,t,st_kc_cell,q_nom,Q,nq,nC,nG,qsc)
q = x(1:nq);
if(qsc.active)
  weights = x(nq+(1:qsc.num_pts));
else
  weights = [];
end
[J,dJ] = IK_cost_fun(obj,q,q_nom,Q);
[c,dc] = IK_constraint_fun(obj,q,t,st_kc_cell,nC,nG,qsc,weights);
f = [J;c];
G = [dJ;dc];
end

function [f,G] = IKtraj_userfun(obj,x,q0,qd0,t,st_kc_cell,mt_kc_cell,q_nom,Qa,Qv,Q,velocity_mat, accel_mat, accel_mat_qd0,accel_mat_qdf,nq,nT,nc_array,nG_array,nf_total,nG_total,q_idx,qsc_weights_idx,qdotf_idx,qsc)
f = zeros(nf_total,1);
G = zeros(nG_total,1);
q = reshape(x(q_idx),nq,nT-1); % q = [q(2), q(3),...,q(nT)];
qsc_weights = reshape(x(qsc_weights_idx),qsc.num_pts,nT-1);
qdotf = x(qdotf_idx);
[f(1),G(1:nq*nT)] = IKtraj_cost_fun(obj,q,qdotf,q0,qd0,q_nom,Qa,Qv,Q,velocity_mat,accel_mat,accel_mat_qd0,accel_mat_qdf,nq,nT);
nf_cum = 1;
nG_cum = nq*nT;
for i = 2:nT
  [f(nf_cum+(1:nc_array(i))),G(nG_cum+(1:nG_array(i)))] = IK_constraint_fun(obj,q(:,i-1),t(i),st_kc_cell,nc_array(i),nG_array(i),qsc,qsc_weights(:,i-1));
  nf_cum = nf_cum+nc_array(i);
  nG_cum = nG_cum+nG_array(i);
end
for i = 1:length(mt_kc_cell)
  mtkc_nc_i = mt_kc_cell{i}.getNumConstraint(t(2:end));
  [f(nf_cum+(1:mtkc_nc_i)),G(nG_cum+(1:mtkc_nc_i*nq*(nT-1)))] = mt_kc_cell{i}.eval(t(2:end),q);
  nf_cum =nf_cum+mtkc_nc_i;
  nG_cum = nG_cum+mtkc_nc_i*nq*(nT-1);
end
end

function [J,dJ] = IK_cost_fun(obj,q,q_nom,Q)
q_err = q-q_nom;
J = q_err'*Q*q_err;
dJ = 2*Q*q_err;
end

function [J,dJ] = IKtraj_cost_fun(obj,q,qdotf,q0,qdot0,q_nom,Qa,Qv,Q,velocity_mat,accel_mat,accel_mat_qd0,accel_mat_qdf,nq,nT)
dJ = zeros(1,nq*nT);
qdot = [reshape(velocity_mat*[q0;q(:)],nq,nT-2) qdotf]; %[qdot(1) qdot(2) ... qdot(nT)]
qddot = reshape(accel_mat*[q0;q(:)]+accel_mat_qd0*qdot0+accel_mat_qdf*qdotf,nq,nT); % [qddot(0) qddot(1) ... qddot(nT)]
q_diff = q-q_nom(:,2:end);
J = 0.5*sum(sum((Qv*qdot).*qdot))...
  +0.5*sum(sum((Q*q_diff).*q_diff))...
  +0.5*sum(sum((Qa*qddot).*qddot));
dJ(1:nq*(nT-1)) = reshape(reshape(Qv*qdot(:,1:end-1),1,[])*velocity_mat(:,nq+1:end),[],1)...
  +reshape(Q*q_diff,[],1)...
  +reshape(reshape(Qa*qddot,1,[])*accel_mat(:,nq+1:end),[],1);
dJ(nq*(nT-1)+(1:nq)) = reshape(reshape(Qa*qddot,1,[])*accel_mat_qdf,[],1)...
  +reshape(qdotf'*Qv,[],1);
end

function [c,G] = IK_constraint_fun(obj,q,t,st_kc_cell,nC,nG,qsc,weights)
c = zeros(nC,1);
G = zeros(nG,1);
kinsol = doKinematics(obj,q,false,false);
nc= 0;
ng = 0;
for i = 1:length(st_kc_cell)
  [cnst,dcnst] = st_kc_cell{i}.eval(t,kinsol);
  ncnst = st_kc_cell{i}.getNumConstraint(t);
  ndcnst = numel(dcnst);
  c(nc+(1:ncnst)) = cnst(:);
  G(ng+(1:ndcnst)) = dcnst(:);
  nc = nc+ncnst;
  ng = ng+ndcnst;
end
if(qsc.active)
  num_qsc_cnst = qsc.getNumConstraint(t);
  [cnst,dcnst] = qsc.eval(t,kinsol,weights);
  c(nc+(1:(num_qsc_cnst-1))) = cnst;
  ndcnst = (num_qsc_cnst-1)*(length(q)+length(weights));
  G(ng+(1:ndcnst)) = dcnst(:);
  nc = nc+num_qsc_cnst;
  ng = ng+ndcnst;
end
end
