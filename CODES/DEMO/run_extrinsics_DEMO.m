%% run_extrinsics
%
% Repeat for each day + flight
%
%   
%   - If using Stability Control Points (like in the CIRN QCIT), you will
%   have to select the search radius area and bright (dark) threshold prior
%   to retriving the extrinsics. 
%
%
%
%
%
%
%
%  Send email that image extraction complete
%
%
% (c) Athina Lange, Coastal Processes Group, Scripps Institution of Oceanography - Sept 2023

%% Do check 
 for dd = 1:length(data_files)
        clearvars -except dd *_dir user_email data_files
        cd(fullfile(data_files(dd).folder, data_files(dd).name))
        
        load(fullfile(data_files(dd).folder, data_files(dd).name, 'input_data.mat'))
        
        % repeat for each flight
        for ff = 1 : length(flights)
            odir = fullfile(flights(ff).folder, flights(ff).name);
            oname = [data_files(dd).name '_' flights(ff).name];
            cd(odir) 

            load(fullfile(odir, 'Processed_data', [oname '_IOEOVariable']),'ind_scp_method')
            %% ========================FeatureDetection============================================
                %           - SMALL CHANGE: in reference to initial image to reduce accumulating drift errors
                %           - LARGE CHANGE: in reference to previous image - correct for accumulated drift later
                %  ===================================================================================
                load(fullfile(odir, 'Processed_data', [oname '_IOEOInitial']),'worldPose', 'R', 'intrinsics')
      
            %% ====================================================================
                for hh = 1 : length(extract_Hz)
                    imageDirectory = sprintf('images_%iHz', extract_Hz(hh));
                    mkdir(sprintf('warped_images_%iHz', extract_Hz(hh)));
                    %% First Frame
                    images = imageDatastore(imageDirectory);
                    
                    viewId = 1
                    prevI = undistortImage(im2gray(readimage(images, 1)), intrinsics); 
                    
                    
                    % Detect features. 
                    prevPoints = detectSURFFeatures(prevI(R.cutoff:end,:), MetricThreshold=500); prevPoints.Location(:,2)=prevPoints.Location(:,2)+R.cutoff;
                    numPoints = 500;
                    prevPoints = selectUniform(prevPoints, numPoints, size(prevI));
                    
                    % Extract features. 
                    prevFeatures = extractFeatures(prevI, prevPoints);
                    
                    ogI = prevI;
                    ogPoints = prevPoints;
                    ogFeatures = prevFeatures;

                    %% 2D
                        for viewId = 2:length(images.Files)
                            % Read and display the next image
                            Irgb = readimage(images, (viewId));
                            
                            % Convert to gray scale and undistort.
                             I = undistortImage(im2gray(Irgb), intrinsics);
                            
                            % WRT OG IMAGE
                            [currPoints, currFeatures, indexPairs] = helperDetectAndMatchFeatures(ogFeatures, I, R.cutoff, numPoints, 'On');
                        
                            % Eliminate outliers from feature matches.
                            [rotation, inlierIdx, scaleRecovered, thetaRecovered] = helperEstimateRotation(ogPoints(indexPairs(:,1)), currPoints(indexPairs(:, 2)));
                            
                            if abs(rotation.RotationAngle) > 5
                                images.Files(viewId:end)=[];
                                break
                            end
                            R.FullRate_OGFrame_2D(viewId) = rotation;
                            if rem(viewId, 30*extract_Hz(hh)) == 0
                                viewId
                                figure(200); clf; I2=imshowpair(undistortImage(readimage(images, 1), intrinsics), ...
                                    imwarp(undistortImage(readimage(images, viewId), intrinsics), R.FullRate_OGFrame_2D(viewId), OutputView=imref2d(size(readimage(images, viewId-1)))));
                                title(sprintf('Time = %.1f min', viewId/extract_Hz(hh)/60))
                                saveas(gca, sprintf('warped_images_%iHz/warped_%isec.jpg', extract_Hz(hh), viewId/extract_Hz(hh)))
                            end
                        end %for viewId = 2:length(images.Files)

                    %% 3D
                        R.FullRate_Adjusted_3D = worldPose;
                        for viewId = 2:length(images.Files)
    
                            % Read and display the next image
                            Irgb = readimage(images, (viewId));
                            
                            % Convert to gray scale and undistort.
                             I = undistortImage(im2gray(Irgb), intrinsics);
    
                             % Detect Features
                            [currPoints, currFeatures, indexPairs] = helperDetectAndMatchFeatures(ogFeatures, I, R.cutoff, numPoints, 'On');
                    
                            try
                                [relPose, inlierIdx] = helperEstimateRelativePose(ogPoints(indexPairs(:,1)), currPoints(indexPairs(:, 2)), intrinsics);
                            catch
                                % Get Essential Matrix 
                                [E, inlierIdx] = estimateEssentialMatrix(ogPoints(indexPairs(:,1)), currPoints(indexPairs(:, 2)), intrinsics);
        
                                % Get the epipolar inliers.
                                indexPairs = indexPairs(inlierIdx,:);
        
                                % Compute the camera pose from the fundamental matrix.
                                [relPose, validPointFraction] = estrelpose(E, intrinsics, ogPoints(indexPairs(:,1)), currPoints(indexPairs(:, 2)));
                            end
    
                            if length(relPose) ~= 1
                                % Do first check if image projection is very wrong - origin of grid should be within image frame
                                [UTMNorthing, UTMEasting, UTMZone] = ll_to_utm(Products(1).lat, Products(1).lon);
                                coords = horzcat(UTMEasting, UTMNorthing, 5.4);
                                for rr = length(relPose):-1:1
                                    aa = worldPose.A *  relPose(rr).A;
                                    absPose = rigidtform3d(aa(1:3,1:3), aa(1:3,4));
                                    iP = world2img(coords, pose2extr(absPose), intrinsics);
                                    if any(any(iP(:)> max(intrinsics.ImageSize))) || any(any(iP(:)< 0))
                                        relPose(rr) = [];
                                    end % if any(any(iP(:)> max(intrinsics.ImageSize))) || any(any(iP(:)< 0))
                                end % for rr = length(relPose):-1:1
                    
                                if length(relPose) ~= 1
                                    % find projection point that is closest Euclidian distance to previous origin point
                                    previP = world2img(coords, pose2extr(R.FullRate_Adjusted_3D(viewId-1)), intrinsics);
                                    clear dist
                                    for rr = 1:length(relPose)
                                        aa = worldPose.A *  relPose(rr).A;
                                        absPose = rigidtform3d(aa(1:3,1:3), aa(1:3,4));
                                        iP = world2img(coords, pose2extr(absPose), intrinsics);
                                        dist(rr) = pdist2(previP, iP);
                                    end % for rr = 1:length(relPose)
                                    [~,i]=min(dist);
                                    relPose = relPose(i);
                                end % if length(relPose) ~= 1
                            end  % if length(relPose) ~= 1
                    
                            R.FullRate_OGFrame_3D(viewId) = relPose;
                            aa = worldPose.A *  relPose.A;
                            absPose = rigidtform3d(aa(1:3,1:3), aa(1:3,4));
                            R.FullRate_Adjusted_3D(viewId) = absPose;

                            if rem(viewId, 30*extract_Hz(hh)) == 0
                                viewId
                                figure(200);clf
                                showMatchedFeatures(ogI,I, ogPoints(indexPairs(:,1)), currPoints(indexPairs(:,2)))
                                 title(sprintf('Time = %.1f min', viewId/extract_Hz(hh)/60))
                                saveas(gca, sprintf('warped_images_%iHz/matching_%isec.jpg', extract_Hz(hh), viewId/extract_Hz(hh)))
                            end
                        end % for viewId = 2:length(images.Files)
                 
                    load(fullfile(odir, 'Processed_data', 'Inital_coordinates'), 'C', 'mov_id')
                    dts = 1/extract_Hz(hh);
                    to = datetime(string(C.CreateDate(mov_id(1))), 'InputFormat', 'yyyy:MM:dd HH:mm:ss', 'TimeZone', tz);
                    to.TimeZone = 'UTC';
                    to = datenum(to);
                    t=(dts./24./3600).*([1:length(images.Files)]-1)+ to;
                    
                  
                    %  Save File
                    save(fullfile(odir, 'Processed_data', [oname '_IOEOVariable_' char(string(extract_Hz(hh))) 'Hz' ]),'R', 'intrinsics', 't')
                    
                end % for hh = 1 : length(extract_Hz)
      
            %% QCIT F
                if exist('user_email', 'var')
                    sendmail(user_email{2}, [oname '- Please start extrinsics through time with SCPs.'])
                end
                answer = questdlg('Ready to start SCPs?', ...
                     'SCPs begin',...
                     'Yes', 'Yes');
        
                %% ========================CIRN_QCIT_F============================================
                for hh = 1 : length(extract_Hz)
                
                    imageDirectory = fullfile(odir, ['images_' char(string(extract_Hz(hh))) 'Hz']);
    
                    % load SCP & extrinsics
                    load(fullfile(odir, 'Processed_data',  [oname '_scpUVdInitial_' char(string(extract_Hz(hh))) 'Hz']), 'scp')
                    load(fullfile(odir, 'Processed_data',  [oname '_IOEOInitial']), 'extrinsics', 'intrinsics_CIRN')
                 
                    L = dir(imageDirectory); L([L.isdir] == 1) = []; if ~isempty(L); L = string(extractfield(L, 'name')');end;  if ~isempty(L); L(L=='.DS_Store')=[];end
      
    
                    In=imread(fullfile(imageDirectory,L(1)));
                    f1=figure;
                    imshow(In)
                    hold on
                    for k=1:length(scp)
                        plot(scp(k).UVdo(1),scp(k).UVdo(2),'ro','linewidth',2,'markersize',10)
                    end
                
                    % Initiate Extrinsics Matrix and First Frame Imagery
                    extrinsicsVariable=nan(length(L),6);
                    extrinsicsVariable(1,:)=extrinsics; % First Value is first frame extrinsics.
                   % extrinsicsUncert(1,:)=initialCamSolutionMeta.extrinsicsUncert;
    
                    [xyzo] = distUV2XYZ(intrinsics_CIRN, extrinsics, reshape([scp.UVdo],2,[]), 'z', [scp.z]);
                    
                    % Initiate and rename initial image, Extrinsics, and SCPUVds for loop
                    extrinsicsVariable(1,:) = extrinsics;
                    scpUVdn_full(1,:,:) = reshape([scp.UVdo],2,[]);
                    imCount=1;
                    click_counter = 0;
                %% ========================SCPthroughTime============================================
                    %                           - Determine search area around bright or dark target. 
                    %  =====================================================================

                    for k=2:length(L)
                        
                        % Assign last Known Extrinsics and SCP UVd coords
                        extrinsics_old=squeeze(extrinsicsVariable(k-1,:));
                        scpUVd_old=squeeze(scpUVdn_full(k-1,:,:));
                        clear extrinsics_new scpUVd_new
    
                        %  Load the New Image
                        In=imread(fullfile(imageDirectory,L(k)));
                        [m,n,~]=size(In);
                        
                        % Find the new UVd coordinate for each SCPs
                        for j=1:length(scp)
                            [Udn, Vdn, i, udi,vdi] = thresholdCenter(In, scpUVd_old(1,j), scpUVd_old(2,j), scp(j).R, scp(j).T, scp(j).brightFlag);
                            if any(isnan([Udn Vdn])) % check if isempty or isnan
                                click_counter = click_counter + 1;
                                if click_counter == 1
                                    if exist('user_email', 'var')
                                        sendmail(user_email{2}, [oname '- Problem with SCPs. Please click on correct point.'])
                                    end
                                end
                                sprintf('Reclick pt: %i', j)
                                fig = figure(100);clf
                                imshow(In)
                                hold on
                                plot(scpUVd_old(1,j),scpUVd_old(2,j),'ro','linewidth',2,'markersize',10)
                                legend('Previous point')
                                xlim([scpUVd_old(1,j)-n/10 scpUVd_old(1,j)+n/10])
                                ylim([scpUVd_old(2,j)-m/10 scpUVd_old(2,j)+m/10])
                    
                                a = drawpoint(); 
                                zoom out
                                Udn= a.Position(1);
                                Vdn= a.Position(2);
                            end
    
                            %Assinging New Coordinate Location
                            scpUVd_new(:,j)=[Udn; Vdn];
                        end % for j=1:length(scp)
                            
                        % Solve For new Extrinsics using last frame extrinsics as initial guess and scps as gcps
                        extrinsicsInitialGuess = extrinsics_old;
                        extrinsicsKnownsFlag = [0 0 0 0 0 0];
                        [extrinsics_new, extrinsicsError] = extrinsicsSolver(extrinsicsInitialGuess,extrinsicsKnownsFlag,intrinsics_CIRN,scpUVd_old',xyzo);
                            
                        % Save Extrinsics in Matrix
                        scpUVdn_full(k,:,:)=scpUVd_new;
                        extrinsicsVariable(k,:)=extrinsics_new;
                        %extrinsicsUncert(imCount,:)=extrinsicsError;
                            
                        % Plot new Image and new UV coordinates, found by threshold and reprojected
                        figure(f1);cla
                       % figure
                        imshow(In)
                        hold on
    
                        % Plot Newly Found UVdn by Threshold
                        plot(scpUVd_new(1,:),scpUVd_new(2,:),'ro','linewidth',2,'markersize',10)
    
                        % Plot Reprojected UVd using new Extrinsics and original xyzo coordinates
                        [UVd] = xyz2DistUV(intrinsics_CIRN,extrinsics_new,xyzo);
                        uvchk = reshape(UVd,[],2);
                        plot(uvchk(:,1),uvchk(:,2),'yo','linewidth',2,'markersize',10)
    
                        tt = char(L(k));
                        title(['Frame: ' tt(7:11)])
                        
                        legend('SCP Threshold','SCP Reprojected')
                        pause(.05)
                        %saveas(gcf, sprintf('people_on_dot/Frame_%i.jpg', k))
                        % 
                    end % for k = 2:length(L)
    
                    
                    %  Saving Extrinsics and corresponding image names
                    extrinsics=extrinsicsVariable;
                    imageNames=L;
                    
                    % Saving MetaData
                    variableCamSolutionMeta.scpPath=fullfile(odir, 'Processed_data',  [oname '_scpUVdInitial_' char(string(extract_Hz(hh))) 'Hz']);
                    variableCamSolutionMeta.scpo=scp;
                    variableCamSolutionMeta.ioeopath=fullfile(odir, 'Processed_data',  [oname '_IOEOInitial']);
                    variableCamSolutionMeta.imageDirectory=imageDirectory;
                    
                    % Calculate Some Statsitics
                    variableCamSolutionMeta.solutionSTD= sqrt(var(extrinsics));
                    
                    %  Save File
                    save(fullfile(odir, 'Processed_data', [oname '_IOEOVariable_' char(string(extract_Hz(hh))) 'Hz' ]),'extrinsics','variableCamSolutionMeta','imageNames','intrinsics_CIRN', '-append')
                    
                    %  Display
                    disp(' ')
                    disp(['Extrinsics for ' num2str(length(L)) ' frames calculated.'])
                    disp(' ')
                    disp(['X Standard Dev: ' num2str(variableCamSolutionMeta.solutionSTD(1))])
                    disp(['Y Standard Dev: ' num2str(variableCamSolutionMeta.solutionSTD(2))])
                    disp(['Z Standard Dev: ' num2str(variableCamSolutionMeta.solutionSTD(3))])
                    disp(['Azimuth Standard Dev: ' num2str(rad2deg(variableCamSolutionMeta.solutionSTD(4))) ' deg'])
                    disp(['Tilt Standard Dev: ' num2str(rad2deg(variableCamSolutionMeta.solutionSTD(5))) ' deg'])
                    disp(['Swing Standard Dev: ' num2str(rad2deg(variableCamSolutionMeta.solutionSTD(6))) ' deg'])
    
                    f2=figure; 
                    f2.Position(4) = 1.5*f2.Position(4);
                    f2.Position(3) = 2*f2.Position(4);
                    
                    % XCoordinate
                    subplot(6,1,1)
                    plot(t,extrinsics(:,1)-extrinsics(1,1))
                    ylabel('\Delta x [m]')
                    title(['Change in Extrinsics over Collection - ' char(string(extract_Hz(hh))) 'Hz'])
                    
                    % YCoordinate
                    subplot(6,1,2)
                    plot(t,extrinsics(:,2)-extrinsics(1,2))
                    ylabel('\Delta y [m]')
                    
                    % ZCoordinate
                    subplot(6,1,3)
                    plot(t,extrinsics(:,3)-extrinsics(1,3))
                    ylabel('\Delta z [m]')
                    
                    % Azimuth
                    subplot(6,1,4)
                    plot(t,rad2deg(extrinsics(:,4)-extrinsics(1,4)))
                    ylabel('\Delta Azimuth [^o]')
                    
                    % Tilt
                    subplot(6,1,5)
                    plot(t,rad2deg(extrinsics(:,5)-extrinsics(1,5)))
                    ylabel('\Delta Tilt[^o]')
                    
                    % Swing
                    subplot(6,1,6)
                    plot(t,rad2deg(extrinsics(:,6)-extrinsics(1,6)))
                    ylabel('\Delta Swing [^o]')
                    
                    for k=1:6
                        subplot(6,1,k)
                        grid on
                        datetick
                    end
                    print(f2, '-dpng', fullfile(odir, 'Processed_data', ['scp_time_' char(string(extract_Hz(hh))) 'Hz.png']))

            end % for hh = 1 : length(extract_Hz)

        if exist('user_email', 'var')
            sendmail(user_email{2}, [oname '- Extrinsics through time DONE'])
        end
    end % for ff = 1 : length(flights)
end % for dd = 1:length(data_files)




%% Functions


function [currPoints, currFeatures, indexPairs] = helperDetectAndMatchFeatures(prevFeatures, I, cutoff, numPoints, UniformTag)
    % Detect and extract features from the current image.
    currPoints   = detectSURFFeatures(I(cutoff:end,:), 'MetricThreshold', 500);currPoints.Location(:,2)=currPoints.Location(:,2)+cutoff;
    if contains('UniformTag', 'On')
        currPoints   = selectUniform(currPoints, numPoints, size(I));
    end
    currFeatures = extractFeatures(I, currPoints);
    
    % Match features between the previous and current image.
    indexPairs = matchFeatures(prevFeatures, currFeatures, 'Unique', true, 'MaxRatio', 0.9);
end

function [tform, inlierIdx, scaleRecovered, thetaRecovered] = helperEstimateRotation(matchedPoints1, matchedPoints2)

    if ~isnumeric(matchedPoints1)
        matchedPoints1 = matchedPoints1.Location;
    end
    
    if ~isnumeric(matchedPoints2)
        matchedPoints2 = matchedPoints2.Location;
    end
    

    [tform, inlierIdx] = estgeotform2d(matchedPoints2, matchedPoints1,'rigid');
    
  
    invTform = invert(tform);
    Ainv = invTform.A;
    
    ss = Ainv(1,2);
    sc = Ainv(1,1);
    scaleRecovered = hypot(ss,sc);
    %disp(['Recovered scale: ', num2str(scaleRecovered)])
    
    % Recover the rotation in which a positive value represents a rotation in
    % the clockwise direction.
    thetaRecovered = atan2d(-ss,sc);
    %disp(['Recovered theta: ', num2str(thetaRecovered)])
    
end

function [relPose, inlierIdx] = helperEstimateRelativePose(matchedPoints1, matchedPoints2, intrinsics)

    if ~isnumeric(matchedPoints1)
        matchedPoints1 = matchedPoints1.Location;
    end
    
    if ~isnumeric(matchedPoints2)
        matchedPoints2 = matchedPoints2.Location;
    end
    
    for i = 1:100
        % Estimate the essential matrix.    
        [E, inlierIdx] = estimateEssentialMatrix(matchedPoints1, matchedPoints2,...
            intrinsics);
    
        % Make sure we get enough inliers
        if sum(inlierIdx) / numel(inlierIdx) < .3
            continue;
        end
        
        % Get the epipolar inliers.
        inlierPoints1 = matchedPoints1(inlierIdx, :);
        inlierPoints2 = matchedPoints2(inlierIdx, :);    
        
        % Compute the camera pose from the fundamental matrix. Use half of the
        % points to reduce computation.
        [relPose, validPointFraction] = ...
            estrelpose(E, intrinsics, inlierPoints1,...
            inlierPoints2);
    
        % validPointFraction is the fraction of inlier points that project in
        % front of both cameras. If the this fraction is too small, then the
        % fundamental matrix is likely to be incorrect.
        if validPointFraction > .7
           return;
        end
    end

    % After 100 attempts validPointFraction is still too low.
    error('Unable to compute the Essential matrix');
  
end
