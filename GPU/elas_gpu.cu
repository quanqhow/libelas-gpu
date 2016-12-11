#include "elas_gpu.h"

using namespace std;



__device__ uint32_t getAddressOffsetImage_GPU (const int32_t& u,const int32_t& v,const int32_t& width) {
  return v*width+u;
}

__device__ uint32_t getAddressOffsetGrid_GPU (const int32_t& x,const int32_t& y,const int32_t& d,const int32_t& width,const int32_t& disp_num) {
  return (y*width+x)*disp_num+d;
}



// Cuda kernel to compute the support points in an image
__global__ void computeMatchingDisparity_GPU(uint8_t *I1_desc, uint8_t *I2_desc, int32_t width, int32_t height,
                                            int16_t *D_can, int32_t D_candidate_stepsize, int32_t D_can_width,
                                            int32_t D_can_height, bool right_image) {
  
  const int32_t u_step      = 2;
  const int32_t v_step      = 2;
  const int32_t window_size = 3;

  // TODO: remove hard coded value
  int32_t support_texture = 10;
  int32_t disp_min = 0;
  int32_t disp_max = 255;
  float support_threshold = 0.95;

  // Global coordinates and Pixel id
  uint32_t u = (blockDim.x*blockIdx.x + threadIdx.x) * D_candidate_stepsize;
  uint32_t v = (blockDim.y*blockIdx.y + threadIdx.y) * D_candidate_stepsize;

  // Candidate matrix coordinates
  uint32_t u_can = blockDim.x*blockIdx.x + threadIdx.x;
  uint32_t v_can = blockDim.y*blockIdx.y + threadIdx.y;
  
  // Get 4 cornering discriptors (NE NE SE SW)
  int32_t desc_offset_1 = -16*u_step-16*width*v_step;
  int32_t desc_offset_2 = +16*u_step-16*width*v_step;
  int32_t desc_offset_3 = -16*u_step+16*width*v_step;
  int32_t desc_offset_4 = +16*u_step+16*width*v_step;

  // Default value
  *(D_can+getAddressOffsetImage_GPU(u_can,v_can,D_can_width)) = -1;

  // Check if we are inside the image region
  if (u>=window_size+u_step && u<=width-window_size-1-u_step && v>=window_size+v_step && v<=height-window_size-1-v_step) {

    // compute desc and start addresses
    int32_t  line_offset = 16*width*v;
    uint8_t *I1_line_addr,*I2_line_addr;
    if (!right_image) {
      I1_line_addr = I1_desc+line_offset;
      I2_line_addr = I2_desc+line_offset;
    } else {
      I1_line_addr = I2_desc+line_offset;
      I2_line_addr = I1_desc+line_offset;
    }

    // compute I1 block start addresses
    uint8_t* I1_block_addr = I1_line_addr+16*u;
    uint8_t* I2_block_addr;
    
    // We require at least some texture
    // Sum intensity values around the candidate
    int32_t sum = 0;
    for (int32_t i=0; i<16; i++)
      sum += abs((int32_t)(*(I1_block_addr+i))-128); //TODO: Why subtract 128
    //If our candidate had a texture below a threshold (Aka not a line) dont use it
    if (sum<support_texture)
      return;

    // declare match energy for each disparity
    int32_t u_warp;
    
    // best match
    int16_t min_1_E = 32767;
    int16_t min_1_d = -1;
    int16_t min_2_E = 32767;
    int16_t min_2_d = -1;

    // get valid disparity range
    int32_t disp_min_valid = max(disp_min,0);
    int32_t disp_max_valid = disp_max;
    //Limits how far we can go out based on window and surrounding candidate points size
    if (!right_image) disp_max_valid = min(disp_max,u-window_size-u_step);
    else              disp_max_valid = min(disp_max,width-u-window_size-u_step);
    
    // assume, that we can compute at least 10 disparities for this pixel
    if (disp_max_valid-disp_min_valid<10)
      return;

    // for all disparities do
    // Interate through our disparity values (at least 10)
    for (int16_t d=disp_min_valid; d<=disp_max_valid; d++) {

      // Warp u coordinate
      // Remember u_warp is applied to the opposite side!
      if (!right_image) u_warp = u-d;
      else              u_warp = u+d;

      // Compute I2 block start addresses
      I2_block_addr = I2_line_addr+16*u_warp;

      // Compute match energy at this disparity
      // Sum all the intensity differences of all the surrounding candidates between the first I1 and second I2 images 
      sum = 0;

      // Get NE candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_1+j))-(int16_t)(*(I2_block_addr+desc_offset_1+j)));
      }
      // Get NW candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_2+j))-(int16_t)(*(I2_block_addr+desc_offset_2+j)));
      }
      // Get SE candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_3+j))-(int16_t)(*(I2_block_addr+desc_offset_3+j)));
      }
      // Get SW candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_4+j))-(int16_t)(*(I2_block_addr+desc_offset_4+j)));
      }

      // best + second best match
      //(Smaller sum = better match)
      if (sum<min_1_E) {
        min_2_E = min_1_E;   
        min_2_d = min_1_d;
        min_1_E = sum;
        min_1_d = d;
      } else if (sum<min_2_E) {
        min_2_E = sum;
        min_2_d = d;
      }
    }

    // check if best and second best match are available and if matching ratio is sufficient
    // Threshold says the second is within the 95th percentile of the first
    if (min_1_d>=0 && min_2_d>=0 && (float)min_1_E<support_threshold*(float)min_2_E) {
      // printf("setting disparity = %d\n", min_1_d);
      *(D_can+getAddressOffsetImage_GPU(u_can,v_can,D_can_width)) = min_1_d;
    }
    else {
      // printf("not-setting disparity = %d | %d | %d | %d \n", min_1_d, min_2_d, min_1_E, support_threshold*(float)min_2_E);
      // *(D_can+getAddressOffsetImage_GPU(u_can,v_can,D_can_width)) = -1;
    }

  }

}


int16_t ElasGPU::computeMatchingDisparity(const int32_t &u,const int32_t &v,uint8_t* I1_desc,uint8_t* I2_desc,const bool &right_image) {

  const int32_t u_step      = 2;
  const int32_t v_step      = 2;
  const int32_t window_size = 3;
  
  // Get 4 cornering descriptors (NE NE SE SW)
  int32_t desc_offset_1 = -16*u_step-16*width*v_step;
  int32_t desc_offset_2 = +16*u_step-16*width*v_step;
  int32_t desc_offset_3 = -16*u_step+16*width*v_step;
  int32_t desc_offset_4 = +16*u_step+16*width*v_step;
  
  __m128i xmm1,xmm2,xmm3,xmm4,xmm5,xmm6;

  // check if we are inside the image region
  if (u>=window_size+u_step && u<=width-window_size-1-u_step && v>=window_size+v_step && v<=height-window_size-1-v_step) {
    
    // compute desc and start addresses
    int32_t  line_offset = 16*width*v;
    uint8_t *I1_line_addr,*I2_line_addr;
    if (!right_image) {
      I1_line_addr = I1_desc+line_offset;
      I2_line_addr = I2_desc+line_offset;
    } else {
      I1_line_addr = I2_desc+line_offset;
      I2_line_addr = I1_desc+line_offset;
    }

    // compute I1 block start addresses
    uint8_t* I1_block_addr = I1_line_addr+16*u;
    uint8_t* I2_block_addr;
    
    // we require at least some texture
    // Sum intensity values around the candidate
    int32_t sum = 0;
    for (int32_t i=0; i<16; i++)
      sum += abs((int32_t)(*(I1_block_addr+i))-128); //TODO: Why subtract 128
    //If our candidate had a texture below a threshold (Aka not a line) dont use it
    if (sum<param.support_texture) 
      return -1;
    
    // load first blocks to xmm registers (Loading corning registers)
    xmm1 = _mm_load_si128((__m128i*)(I1_block_addr+desc_offset_1));
    xmm2 = _mm_load_si128((__m128i*)(I1_block_addr+desc_offset_2));
    xmm3 = _mm_load_si128((__m128i*)(I1_block_addr+desc_offset_3));
    xmm4 = _mm_load_si128((__m128i*)(I1_block_addr+desc_offset_4));
    
    // declare match energy for each disparity
    int32_t u_warp;
    
    // best match
    int16_t min_1_E = 32767;
    int16_t min_1_d = -1;
    int16_t min_2_E = 32767;
    int16_t min_2_d = -1;

    // get valid disparity range
    int32_t disp_min_valid = max(param.disp_min,0);
    int32_t disp_max_valid = param.disp_max;
    //Limits how far we can go out based on window and surrounding candidate points size
    if (!right_image) disp_max_valid = min(param.disp_max,u-window_size-u_step);
    else              disp_max_valid = min(param.disp_max,width-u-window_size-u_step);
    
    // assume, that we can compute at least 10 disparities for this pixel
    if (disp_max_valid-disp_min_valid<10)
      return -1;

    // for all disparities do
    // Interate through our disparity values (at least 10)
    for (int16_t d=disp_min_valid; d<=disp_max_valid; d++) {

      // warp u coordinate
      // Remember u_warp is applied to the opposite side!
      if (!right_image) u_warp = u-d;
      else              u_warp = u+d;

      // compute I2 block start addresses
      I2_block_addr = I2_line_addr+16*u_warp;

      // compute match energy at this disparity
      // Sum all the intensity differences of all the surrounding candidates between the first I1 and second I2 images 
      // Get NE candidate from image 2
      xmm6 = _mm_load_si128((__m128i*)(I2_block_addr+desc_offset_1));
      //_mm_sad_epu8 sums the difference of the first 64 bytes and second 64 bytes (returns 2 values)
      xmm6 = _mm_sad_epu8(xmm1,xmm6); //Subtract the two values from image 1 and image 2
      sum = 0;
      // Get NE candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_1+j))-(int16_t)(*(I2_block_addr+desc_offset_1+j)));
      }

      // Get NW candidate from image 2
      xmm5 = _mm_load_si128((__m128i*)(I2_block_addr+desc_offset_2));
      xmm6 = _mm_add_epi16(_mm_sad_epu8(xmm2,xmm5),xmm6);
      // Get NW candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_2+j))-(int16_t)(*(I2_block_addr+desc_offset_2+j)));
      }

      // Get SE candidate from image 2
      xmm5 = _mm_load_si128((__m128i*)(I2_block_addr+desc_offset_3));
      xmm6 = _mm_add_epi16(_mm_sad_epu8(xmm3,xmm5),xmm6);
      // Get SE candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_3+j))-(int16_t)(*(I2_block_addr+desc_offset_3+j)));
      }

      // Get SW candidate from image 2
      xmm5 = _mm_load_si128((__m128i*)(I2_block_addr+desc_offset_4));
      xmm6 = _mm_add_epi16(_mm_sad_epu8(xmm4,xmm5),xmm6);
      // Get SW candidate from image 2
      for(int j=0; j<16; j++){
          sum += abs((int16_t)(*(I1_block_addr+desc_offset_4+j))-(int16_t)(*(I2_block_addr+desc_offset_4+j)));
      }

      // Testing, compare
      int32_t temp = _mm_extract_epi16(xmm6,0)+_mm_extract_epi16(xmm6,4); //Sum all the differences
      if(sum != temp) {
        printf("sum = %d  |  temp = %d\n", sum, temp);
        sum = temp;
      }

      // best + second best match
      //(Smaller sum = better match)
      if (sum<min_1_E) {
        min_2_E = min_1_E;   
        min_2_d = min_1_d;
        min_1_E = sum;
        min_1_d = d;
      } else if (sum<min_2_E) {
        min_2_E = sum;
        min_2_d = d;
      }
    }

    // check if best and second best match are available and if matching ratio is sufficient
    // Threshold says the second is within the 95th percentile of the first
    if (min_1_d>=0 && min_2_d>=0 && (float)min_1_E<param.support_threshold*(float)min_2_E)
      return min_1_d;
    else
      return -1;
    
  } else
    return -1;


}


/*
* Computes the disparity for each support point candidate 
* Removes outlier and redundant support points
*/
vector<Elas::support_pt> ElasGPU::computeSupportMatches(uint8_t* I1_desc,uint8_t* I2_desc) {

  // be sure that at half resolution we only need data
  // from every second line!
  int32_t D_candidate_stepsize = param.candidate_stepsize; //Stride over candidates for discriptors
  if (param.subsampling)
    D_candidate_stepsize += D_candidate_stepsize%2;

  // create matrix for saving disparity candidates
  int32_t D_can_width  = 0;
  int32_t D_can_height = 0;
  for (int32_t u=0; u<width;  u+=D_candidate_stepsize) D_can_width++; //Determine number of candidates at the stepsize in the horizontal
  for (int32_t v=0; v<height; v+=D_candidate_stepsize) D_can_height++; //Determine number of candidates at the stepsize in the vertical  
  
  // Calculate size of kernel
  int block_width = 8;
  int block_height = block_width;
  int grid_width, grid_height;

  // Calculate grid_size
  if(D_can_width%block_width == 0) {
      grid_width = ceil(D_can_width/block_width);
  } else {
      grid_width = ceil(D_can_width/block_width); + 1;
  }

  if(D_can_height%block_height == 0) {
      grid_height = ceil(D_can_height/block_height);
  } else {
      grid_height = ceil(D_can_height/block_height); + 1;
  }

  // Local disparity grids
  int16_t* D_can_1 = (int16_t*)calloc(D_can_width*D_can_height,sizeof(int16_t));
  int16_t* D_can_2 = (int16_t*)calloc(D_can_width*D_can_height,sizeof(int16_t));

  cout << "D_can_height = " << D_can_height << endl;
  cout << "D_can_width = " << D_can_width << endl;
  // cout << "block_width = " << block_width << endl;
  // cout << "block_height = " << block_height << endl;
  // cout << "grid_width = " << grid_width << endl;
  // cout << "grid_height = " << grid_height << endl;

   // Create size objects
  dim3 DimGrid(grid_width,grid_height,1);
  dim3 DimBlock(block_width,block_height,1);

  // Create two streams to the GPU
  // cudaStream_t streams[2];
  // cudaStreamCreate(&streams[0]);
  // cudaStreamCreate(&streams[1]);

  //CUDA events
  float milliseconds;
  cudaEvent_t memstart, memstop, lstart, lstop;
  cudaEventCreate(&memstart);
  cudaEventCreate(&memstop);
  cudaEventCreate(&lstart);
  cudaEventCreate(&lstop);


  cudaEventRecord(memstart);

  // CUDA copy over needed memory information
  // candidate disparity grid, and image descriptors
  int16_t *d_D_can_LR, *d_D_can_RL;
  uint8_t *d_I1, *d_I2;

  // Allocate on global memory and copy
  cudaMalloc((void**) &d_D_can_LR, D_can_width*D_can_height*sizeof(int16_t));
  CUDA_CHECK_ERROR();
  // cudaMalloc((void**) &d_D_can_RL, D_can_width*D_can_height*sizeof(int16_t));
  CUDA_CHECK_ERROR();
  cudaMalloc((void**) &d_I1, 16*width*height*sizeof(uint8_t)); //Device descriptors
  CUDA_CHECK_ERROR();
  cudaMalloc((void**) &d_I2, 16*width*height*sizeof(uint8_t)); //Device descriptors
  CUDA_CHECK_ERROR();


  // Now copy over data
  cudaMemcpy(d_I1, I1_desc, 16*width*height*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_I2, I2_desc, 16*width*height*sizeof(uint8_t), cudaMemcpyHostToDevice);
  // cudaMemcpy(d_D_can_LR, D_can_1, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyHostToDevice);
  // cudaMemcpy(d_D_can_RL, D_can_2, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyHostToDevice);
  // cudaMemcpyAsync(d_D_can_LR, D_can_1, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyHostToDevice, streams[0]);
  // cudaMemcpyAsync(d_D_can_RL, D_can_2, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyHostToDevice, streams[1]);

  CUDA_CHECK_ERROR();
  cudaEventRecord(lstart);

  // KERNEL: Compute disparities left to right
  computeMatchingDisparity_GPU<<<DimGrid,DimBlock,0>>>(d_I1, d_I2, width, height,
                                                                  d_D_can_LR, D_candidate_stepsize, D_can_width,
                                                                  D_can_height, false);


  CUDA_CHECK_ERROR();
  // cudaDeviceSynchronize();
  cudaEventSynchronize(lstart);
  cudaEventRecord(lstop);
  cudaEventSynchronize(lstop);
  cudaEventElapsedTime(&milliseconds, lstart, lstop);
  fprintf(stdout, "Code Logic Wall-Clock(ms) = %lf\n", milliseconds);
  CUDA_CHECK_ERROR();
  

  cudaMemcpy(D_can_1, d_D_can_LR, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyDeviceToHost);
  CUDA_CHECK_ERROR();
  cudaFree(d_D_can_LR);
  CUDA_CHECK_ERROR();
  //cudaMalloc((void**) &d_D_can_RL, D_can_width*D_can_height*sizeof(int16_t));
  //CUDA_CHECK_ERROR();

  cudaEventRecord(memstop);
  cudaEventSynchronize(memstart);
  cudaEventSynchronize(memstop);
  cudaEventElapsedTime(&milliseconds, memstart, memstop);
  fprintf(stdout, "Memory copy wall-clock(ms) = %lf\n", milliseconds);

  // KERNEL: Compute disparities right to left
  // computeMatchingDisparity_GPU<<<DimGrid,DimBlock,0>>>(d_I1, d_I2, width, height,
  //                                                                 d_D_can_RL, D_candidate_stepsize, D_can_width,
  //                                                                 D_can_height, true);


  // Copy the final disparity candidate values back over
  // cudaMemcpyAsync(D_can_1, d_D_can_LR, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyDeviceToHost, streams[0]);
  // cudaMemcpy(D_can_1, d_D_can_LR, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyDeviceToHost);
  // cudaMemcpyAsync(D_can_2, d_D_can_RL, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyDeviceToHost, streams[1]);
  //cudaMemcpy(D_can_2, d_D_can_RL, D_can_width*D_can_height*sizeof(int16_t), cudaMemcpyDeviceToHost);
  //CUDA_CHECK_ERROR();

  // Sync after the kernel is launched
  // Ensures we have copied this data back to the host
  //cudaDeviceSynchronize();
  //CUDA_CHECK_ERROR();

  // TODO: Remove this logic, this is here so we can call the other methods
  int16_t* D_can = (int16_t*)calloc(D_can_width*D_can_height,sizeof(int16_t));
  for (int32_t u_can=1; u_can<D_can_width; u_can++) {
    for (int32_t v_can=1; v_can<D_can_height; v_can++) {
      // Get the two left and right disp
      int16_t d1 = *(D_can_1+getAddressOffsetImage(u_can,v_can,D_can_width));
      //int16_t d2 = *(D_can_2+getAddressOffsetImage(u_can,v_can,D_can_width));
      // Compare their values
      // if (d1>0 && d2>0 && abs(d1-d2)<=param.lr_threshold) {
      //   // cout << "setting (" << u_can << ", " << v_can << ") = " << d1 << " | " << d2 << endl;
      //   *(D_can+getAddressOffsetImage(u_can,v_can,D_can_width)) = d1;
      // } else {
      //   // cout << "not-setting (" << u_can << ", " << v_can << ") = " << d1 << " | " << d2 << endl;
      //   *(D_can+getAddressOffsetImage(u_can,v_can,D_can_width)) = -1;
      // }

      //If we have found a disparity in the left, check from the right to left disparity
      if (d1>=0) {
        int16_t u = u_can*D_candidate_stepsize;
        int16_t v = v_can*D_candidate_stepsize;
        // find backwards
        int16_t d2 = computeMatchingDisparity(u-d1,v,I1_desc,I2_desc,true);
        //Check our error between the 2 disparity and that its below 2 pixel difference
        if (d2>=0 && abs(d1-d2)<=param.lr_threshold)
            //TODO: Use average of the two? Why only the left?
          *(D_can+getAddressOffsetImage(u_can,v_can,D_can_width)) = d1; //Save disparity 
      }

    }
  }

  // TODO: Make this a kernel
  // Remove inconsistent support points
  removeInconsistentSupportPoints(D_can,D_can_width,D_can_height);

  // TODO: Make this a kernel
  // Remove support points on straight lines, since they are redundant
  // this reduces the number of triangles a little bit and hence speeds up
  // the triangulation process
  removeRedundantSupportPoints(D_can,D_can_width,D_can_height,5,1,true);
  removeRedundantSupportPoints(D_can,D_can_width,D_can_height,5,1,false);
  
  // Move support points from image representation into a vector representation
  vector<support_pt> p_support;
  for (int32_t u_can=1; u_can<D_can_width; u_can++)
    for (int32_t v_can=1; v_can<D_can_height; v_can++)
      if (*(D_can+getAddressOffsetImage(u_can,v_can,D_can_width))>=0)
        p_support.push_back(support_pt(u_can*D_candidate_stepsize,
                                       v_can*D_candidate_stepsize,
                                       *(D_can+getAddressOffsetImage(u_can,v_can,D_can_width))));
  
  // if flag is set, add support points in image corners
  // with the same disparity as the nearest neighbor support point
  if (param.add_corners)
    addCornerSupportPoints(p_support);

  // free memory
  free(D_can);
  free(D_can_1);
  free(D_can_2);

  // Cuda frees
  // cudaFree(d_D_can_LR);
  // cudaFree(d_D_can_RL);
  cudaFree(d_I1);
  cudaFree(d_I2);

  // return support point vector
  return p_support;

}




/**
 * CUDA Kernel for computing the match for a single UV coordinate
 */
__global__ void findMatch_GPU(int32_t* u_vals, int32_t* v_vals, int32_t size_total, float* planes_a, float* planes_b, float* planes_c,
                         int32_t* disparity_grid, int32_t *grid_dims, uint8_t* I1_desc, uint8_t* I2_desc,
                         int32_t* P, int32_t plane_radius, int32_t width ,int32_t height, bool* valids, bool right_image, float* D,
                         bool subsampling, int32_t match_texture, int32_t grid_size) {
 
  // get image width and height
  const int32_t disp_num    = grid_dims[0]-1;
  const int32_t window_size = 2;

  // Pixel id
  uint32_t idx = blockDim.x*blockIdx.x + threadIdx.x;

  // Check that we are in range
  if(idx >= size_total)
    return;

  // Else get our values from memory
  uint32_t u = u_vals[idx];
  uint32_t v = v_vals[idx];
  float plane_a = planes_a[idx];
  float plane_b = planes_b[idx];
  float plane_c = planes_c[idx];
  bool valid = valids[idx];

  // address of disparity we want to compute
  uint32_t d_addr;
  if (subsampling) d_addr = getAddressOffsetImage_GPU(u/2,v/2,width/2);
  else             d_addr = getAddressOffsetImage_GPU(u,v,width);
  
  // check if u is ok
  if (u<window_size || u>=width-window_size)
    return;

  // compute line start address
  int32_t  line_offset = 16*width*max(min(v,height-3),2);
  uint8_t *I1_line_addr,*I2_line_addr;
  if (!right_image) {
    I1_line_addr = I1_desc+line_offset;
    I2_line_addr = I2_desc+line_offset;
  } else {
    I1_line_addr = I2_desc+line_offset;
    I2_line_addr = I1_desc+line_offset;
  }

  // compute I1 block start address
  uint8_t* I1_block_addr = I1_line_addr+16*u;
  
  // does this patch have enough texture?
  int32_t sum = 0;
  for (int32_t i=0; i<16; i++)
    sum += abs((int32_t)(*(I1_block_addr+i))-128);
  if (sum<match_texture)
    return;

  // compute disparity, min disparity and max disparity of plane prior
  int32_t d_plane     = (int32_t)(plane_a*(float)u+plane_b*(float)v+plane_c);
  int32_t d_plane_min = max(d_plane-plane_radius,0);
  int32_t d_plane_max = min(d_plane+plane_radius,disp_num-1);

  // get grid pointer
  int32_t  grid_x    = (int32_t)floor((float)u/(float)grid_size);
  int32_t  grid_y    = (int32_t)floor((float)v/(float)grid_size);
  uint32_t grid_addr = getAddressOffsetGrid_GPU(grid_x,grid_y,0,grid_dims[1],grid_dims[0]);  
  int32_t  num_grid  = *(disparity_grid+grid_addr);
  int32_t* d_grid    = disparity_grid+grid_addr+1;
  
  // loop variables
  int32_t d_curr, u_warp, val;
  int32_t min_val = 10000;
  int32_t min_d   = -1;

  // left image
    for (int32_t i=0; i<num_grid; i++) {
      d_curr = d_grid[i];
      if (d_curr<d_plane_min || d_curr>d_plane_max) { //If the current disparity is out of the planes range
        u_warp = u-d_curr+2*right_image*d_curr; //uwarp diffe
        if (u_warp<window_size || u_warp>=width-window_size)
          continue;
        u_warp = 16*u_warp;
        val = 0;
        for(int j=0; j<16; j++){
            //val += abs((int32_t)(*(I1_block_addr+j))-(int32_t)(*(I2_line_addr+j+16*u_warp)));
            val = __sad((int)(*(I1_block_addr+j)),(int)(*(I2_line_addr+j+u_warp)),val);
        }
        
        if (val<min_val) {
            min_val = val;
            min_d   = d_curr;
        }
      }
    }
    //disparity inside the grid
    for (d_curr=d_plane_min; d_curr<=d_plane_max; d_curr++) {
            u_warp = u-d_curr+2*right_image*d_curr;
      if (u_warp<window_size || u_warp>=width-window_size)
        continue;
      u_warp = 16*u_warp;
      val = 0;
      for(int j=0; j<16; j++){
          //val += abs((int32_t)(*(I1_block_addr+j))-(int32_t)(*(I2_line_addr+j+16*u_warp)));
          val = __sad((int)(*(I1_block_addr+j)),(int)(*(I2_line_addr+j+u_warp)),val);
      }
      val += valid?*(P+abs(d_curr-d_plane)):0;
      if (val<min_val) {
        min_val = val;
        min_d   = d_curr;
      }
    }

  // set disparity value
  if (min_d>=0) *(D+d_addr) = min_d; // MAP value (min neg-Log probability)
  else          *(D+d_addr) = -1;    // invalid disparity
}

/**
 * This is the core method that computes the disparity of the image
 * It processes each triangle, so we create a kernel and have each thread
 * compute the matches in each triangle
 */
void ElasGPU::computeDisparity(std::vector<support_pt> p_support, std::vector<triangle> tri, int32_t* disparity_grid, int32_t *grid_dims,
                                uint8_t* I1_desc, uint8_t* I2_desc, bool right_image, float* D) {

  // number of disparities
  const int32_t disp_num  = grid_dims[0]-1;
  
  // descriptor window_size
  int32_t window_size = 2;
  
  // init disparity image to -10
  if (param.subsampling) {
    for (int32_t i=0; i<(width/2)*(height/2); i++)
      *(D+i) = -10;
  } else {
    for (int32_t i=0; i<width*height; i++)
      *(D+i) = -10;
  }
  
  // pre-compute prior 
  float two_sigma_squared = 2*param.sigma*param.sigma;
  int32_t* P = new int32_t[disp_num];
  for (int32_t delta_d=0; delta_d<disp_num; delta_d++)
    P[delta_d] = (int32_t)((-log(param.gamma+exp(-delta_d*delta_d/two_sigma_squared))+log(param.gamma))/param.beta);
  int32_t plane_radius = (int32_t)max((float)ceil(param.sigma*param.sradius),(float)2.0);

  // loop variables
  int32_t c1, c2, c3, offset;
  float plane_a,plane_b,plane_c,plane_d,milliseconds;

  // Size variables
  int32_t size_total = 0;
  int32_t size_grid = width*height;

  // Master objects that will need to be created
  // These will be passed to the CUDA kernel after converted
  float* planes_a = new float[size_grid];
  float* planes_b = new float[size_grid];
  float* planes_c = new float[size_grid];
  int32_t* pixs_u = new int32_t[size_grid];
  int32_t* pixs_v = new int32_t[size_grid];
  bool* valids = new bool[size_grid];


  // for all triangles do
  for (uint32_t i=0; i<tri.size(); i++) {
    
    // get plane parameters
    uint32_t p_i = i*3;
    if (!right_image) {
      plane_a = tri[i].t1a;
      plane_b = tri[i].t1b;
      plane_c = tri[i].t1c;
      plane_d = tri[i].t2a;
    } else {
      plane_a = tri[i].t2a;
      plane_b = tri[i].t2b;
      plane_c = tri[i].t2c;
      plane_d = tri[i].t1a;
    }

    // triangle corners
    c1 = tri[i].c1;
    c2 = tri[i].c2;
    c3 = tri[i].c3;

    // sort triangle corners wrt. u (ascending)    
    float tri_u[3];
    if (!right_image) {
      tri_u[0] = p_support[c1].u;
      tri_u[1] = p_support[c2].u;
      tri_u[2] = p_support[c3].u;
    } else {
      tri_u[0] = p_support[c1].u-p_support[c1].d;
      tri_u[1] = p_support[c2].u-p_support[c2].d;
      tri_u[2] = p_support[c3].u-p_support[c3].d;
    }
    float tri_v[3] = {p_support[c1].v,p_support[c2].v,p_support[c3].v};
    
    for (uint32_t j=0; j<3; j++) {
      for (uint32_t k=0; k<j; k++) {
        if (tri_u[k]>tri_u[j]) {
          float tri_u_temp = tri_u[j]; tri_u[j] = tri_u[k]; tri_u[k] = tri_u_temp;
          float tri_v_temp = tri_v[j]; tri_v[j] = tri_v[k]; tri_v[k] = tri_v_temp;
        }
      }
    }

    // rename corners
    float A_u = tri_u[0]; float A_v = tri_v[0];
    float B_u = tri_u[1]; float B_v = tri_v[1];
    float C_u = tri_u[2]; float C_v = tri_v[2];
    
    // compute straight lines connecting triangle corners
    float AB_a = 0; float AC_a = 0; float BC_a = 0;
    if ((int32_t)(A_u)!=(int32_t)(B_u)) AB_a = (A_v-B_v)/(A_u-B_u);
    if ((int32_t)(A_u)!=(int32_t)(C_u)) AC_a = (A_v-C_v)/(A_u-C_u);
    if ((int32_t)(B_u)!=(int32_t)(C_u)) BC_a = (B_v-C_v)/(B_u-C_u);
    float AB_b = A_v-AB_a*A_u;
    float AC_b = A_v-AC_a*A_u;
    float BC_b = B_v-BC_a*B_u;
    
    // a plane is only valid if itself and its projection
    // into the other image is not too much slanted
    bool valid = fabs(plane_a)<0.7 && fabs(plane_d)<0.7;

    // Vector of all u,v pairs we need to calculate
    std::vector<int32_t> temp_val_u = std::vector<int32_t>();
    std::vector<int32_t> temp_val_v = std::vector<int32_t>();
        
    // first part (triangle corner A->B)
    if ((int32_t)(A_u)!=(int32_t)(B_u)) {
      // Starting at A_u loop till the B_u or the end of the image
      for (int32_t u=max((int32_t)A_u,0); u<min((int32_t)B_u,width); u++){
        // If we are sub-sampling skip every two
        if (!param.subsampling || u%2==0) {
          // Use linear lines, to get the bounds of where we need to check
          int32_t v_1 = (uint32_t)(AC_a*(float)u+AC_b);
          int32_t v_2 = (uint32_t)(AB_a*(float)u+AB_b);
          // Loop through these values of v and try to find the match
          for (int32_t v=min(v_1,v_2); v<max(v_1,v_2); v++)
            // If we are sub-sampling skip every two
            if (!param.subsampling || v%2==0) {
              temp_val_u.push_back(u);
              temp_val_v.push_back(v);
            }
        }
      }
    }

    // second part (triangle corner B->C)
    if ((int32_t)(B_u)!=(int32_t)(C_u)) {
      for (int32_t u=max((int32_t)B_u,0); u<min((int32_t)C_u,width); u++){
        if (!param.subsampling || u%2==0) {
          int32_t v_1 = (uint32_t)(AC_a*(float)u+AC_b);
          int32_t v_2 = (uint32_t)(BC_a*(float)u+BC_b);
          for (int32_t v=min(v_1,v_2); v<max(v_1,v_2); v++)
            if (!param.subsampling || v%2==0) {
              temp_val_u.push_back(u);
              temp_val_v.push_back(v);
            }
        }
      }
    }

    // Append to our master u,v vector
    for(size_t j=0; j<temp_val_u.size(); j++) {

      // Set values for our planes
      planes_a[size_total] = plane_a;
      planes_b[size_total] = plane_b;
      planes_c[size_total] = plane_c;

      // Pixel u,v coords
      pixs_u[size_total] = temp_val_u.at(j);
      pixs_v[size_total] = temp_val_v.at(j);

      // Set if valid
      valids[size_total] = valid;

      // Move forward in time
      size_total++;
    }
  }
    
  // Debug
  cout << "Original Size: " << size_grid << endl;
  cout << "Total Size: " << size_total << endl;

  // Calculate size of kernel
  int block_size = 32;
  int grid_size = 0;

  //Calculate grid_size (add 1 if not evenly divided)
  if(size_total%block_size == 0) {
      grid_size = ceil(size_total/block_size);
  } else {
      grid_size = ceil(size_total/block_size) + 1;
  }

  // Create size objects
  dim3 DimGrid(grid_size,1,1);
  dim3 DimBlock(block_size,1,1);

  // Allocate u,v pointer array
  int32_t* d_u_vals, *d_v_vals;
  cudaMalloc((void**) &d_u_vals, size_total*sizeof(int32_t));
  cudaMalloc((void**) &d_v_vals, size_total*sizeof(int32_t));

  // Copy over pointer array
  cudaMemcpy(d_u_vals, pixs_u, size_total*sizeof(int32_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_v_vals, pixs_v, size_total*sizeof(int32_t), cudaMemcpyHostToDevice);

  // Copy over the plane values
  float* d_planes_a, *d_planes_b, *d_planes_c;
  cudaMalloc((void**) &d_planes_a, size_total*sizeof(float));
  cudaMalloc((void**) &d_planes_b, size_total*sizeof(float));
  cudaMalloc((void**) &d_planes_c, size_total*sizeof(float));
  cudaMemcpy(d_planes_a, planes_a, size_total*sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_planes_b, planes_b, size_total*sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_planes_c, planes_c, size_total*sizeof(float), cudaMemcpyHostToDevice);
  
  // Copy over valid
  bool* d_valids;
  cudaMalloc((void**) &d_valids, size_total*sizeof(bool));
  cudaMemcpy(d_valids, valids, size_total*sizeof(bool), cudaMemcpyHostToDevice);

  // CUDA copy over needed memory information
  // disparity_grid, I1_desc,I2_desc,P,D
  int32_t* d_disparity_grid, *d_grid_dims;
  int32_t* d_P;
  float* d_D;
  uint8_t* d_I1, *d_I2;

  // Allocate on global memory
  cudaMalloc((void**) &d_disparity_grid, grid_dims[0]*grid_dims[1]*grid_dims[2]*sizeof(int32_t));
  cudaMalloc((void**) &d_P, disp_num*sizeof(int32_t));
  cudaMalloc((void**) &d_D, width*height*sizeof(float));
  cudaMalloc((void**) &d_I1, 16*width*height*sizeof(uint8_t)); //Device descriptors
  cudaMalloc((void**) &d_I2, 16*width*height*sizeof(uint8_t)); //Device descriptors
  cudaMalloc((void**) &d_grid_dims, 3*sizeof(int32_t)); 

  // Now copy over data
  cudaMemcpy(d_disparity_grid, disparity_grid, grid_dims[0]*grid_dims[1]*grid_dims[2]*sizeof(int32_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_grid_dims, grid_dims, 3*sizeof(int32_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_P, P, disp_num*sizeof(int32_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_D, D, width*height*sizeof(float), cudaMemcpyHostToDevice);
  cudaMemcpy(d_I1, I1_desc, 16*width*height*sizeof(uint8_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_I2, I2_desc, 16*width*height*sizeof(uint8_t), cudaMemcpyHostToDevice);

  // Launch the kernel
  findMatch_GPU<<<DimGrid, DimBlock>>>(d_u_vals, d_v_vals, size_total, d_planes_a, d_planes_b, d_planes_c,
                                        d_disparity_grid, d_grid_dims, d_I1, d_I2, d_P, plane_radius,
                                        width, height, d_valids, right_image, d_D,
                                        param.subsampling, param.match_texture, param.grid_size);
    
  // Sync after the kernel is launched
  cudaDeviceSynchronize();

  // Copy the final disparity values back over
  cudaMemcpy(D, d_D, width*height*sizeof(float), cudaMemcpyDeviceToHost);
  
  // Free local memory
  delete[] P;

  // Delete host code
  delete planes_a;
  delete planes_b;
  delete planes_c;
  delete pixs_u;
  delete pixs_v;
  delete valids;

  // Free big memory
  cudaFree(d_u_vals);
  cudaFree(d_v_vals);
  cudaFree(d_planes_a);
  cudaFree(d_planes_b);
  cudaFree(d_planes_c);

  // Free cuda memory
  cudaFree(d_disparity_grid);
  cudaFree(d_P);
  cudaFree(d_D);
  cudaFree(d_I1);
  cudaFree(d_I2);
  cudaFree(d_grid_dims);
  cudaFree(d_u_vals);
  cudaFree(d_v_vals);

}

// implements approximation to 8x8 bilateral filtering
__global__ void adaptiveMeanGPU8 (float* D, int32_t D_width, int32_t D_height) {
  
  // Global coordinates and Pixel id
  uint32_t u0 = blockDim.x*blockIdx.x + threadIdx.x + 4;
  uint32_t v0 = blockDim.y*blockIdx.y + threadIdx.y + 4;
  uint32_t idx = v0*D_width + u0;
  //Local thread coordinates
  uint32_t ut = threadIdx.x + 4;
  uint32_t vt = threadIdx.y + 4;
  
  //If out of filter range return instantly
  if(u0 > (D_width - 4) || v0 > (D_height - 4))
    return;

  //Allocate Shared memory array with an appropiate margin for the bitlateral filter
  //Since we are using 8 pixels with the center pixel being 5,
  //we need 4 extra on left and top and 3 extra on right and bottom
  __shared__ float D_shared[32+7][32+7];
  //Populate shared memory
  if(threadIdx.x == blockDim.x-1){
      D_shared[ut+1][vt] = D[idx+1];
      D_shared[ut+2][vt] = D[idx+2];
      D_shared[ut+3][vt] = D[idx+3];
      //D_shared[ut+4][vt] = D[idx+4];
  }
  if(threadIdx.x == 0){
      D_shared[ut-4][vt] = D[idx-4];
      D_shared[ut-3][vt] = D[idx-3];
      D_shared[ut-2][vt] = D[idx-2];
      D_shared[ut-1][vt] = D[idx-1];
  }
  if(threadIdx.y == 0){
      D_shared[ut][vt-4] = D[(v0-4)*D_width+u0];
      D_shared[ut][vt-3] = D[(v0-3)*D_width+u0];
      D_shared[ut][vt-2] = D[(v0-2)*D_width+u0];
      D_shared[ut][vt-1] = D[(v0-1)*D_width+u0];
  }
  if(threadIdx.y == blockDim.y-1){
      D_shared[ut][vt+1] = D[(v0+1)*D_width+u0];
      D_shared[ut][vt+2] = D[(v0+2)*D_width+u0];
      D_shared[ut][vt+3] = D[(v0+3)*D_width+u0];
      //D_shared[ut][vt+4] = D[(v0+4)*D_width+u0];
  }

  if(D[idx] < 0){
      // zero input disparity maps to -10 (this makes the bilateral
      // weights of all valid disparities to 0 in this region)
      D_shared[ut][vt] = -10;
  }else{
      D_shared[ut][vt] = D[idx];
  }
  __syncthreads();
      
  // full resolution: 8 pixel bilateral filter width
  // D(x) = sum(I(xi)*f(I(xi)-I(x))*g(xi-x))/W(x)
  // W(x) = sum(f(I(xi)-I(x))*g(xi-x))
  // g(xi-x) = 1
  // f(I(xi)-I(x)) = 4-|I(xi)-I(x)| if greater than 0, 0 otherwise
  // horizontal filter

  // Current pixel being filtered is middle of our set (4 back, in orginal its 3 for some reason)
  //Note this isn't truely the center since original uses 8 vectore resisters
  float val_curr = D_shared[ut][vt];

  float weight_sum0 = 0;
  float weight_sum = 0;
  float factor_sum = 0;

  for(int32_t i=0; i < 8; i++){
    weight_sum0 = 4.0f - fabs(D_shared[ut+(i-4)][vt]-val_curr);
    weight_sum0 = max(0.0f, weight_sum0);
    weight_sum += weight_sum0;
    factor_sum += D_shared[ut+(i-4)][vt]*weight_sum0;
  }

  if (weight_sum>0) {
      float d = factor_sum/weight_sum;
      if (d>=0) *(D+idx) = d;
  }
  
  __syncthreads();
  //Update shared memory
  if(threadIdx.x == blockDim.x-1){
      D_shared[ut+1][vt] = D[idx+1];
      D_shared[ut+2][vt] = D[idx+2];
      D_shared[ut+3][vt] = D[idx+3];
      //D_shared[ut+4][vt] = D[idx+4];
  }
  if(threadIdx.x == 0){
      D_shared[ut-4][vt] = D[idx-4];
      D_shared[ut-3][vt] = D[idx-3];
      D_shared[ut-2][vt] = D[idx-2];
      D_shared[ut-1][vt] = D[idx-1];
  }
  if(threadIdx.y == 0){
      D_shared[ut][vt-4] = D[(v0-4)*D_width+u0];
      D_shared[ut][vt-3] = D[(v0-3)*D_width+u0];
      D_shared[ut][vt-2] = D[(v0-2)*D_width+u0];
      D_shared[ut][vt-1] = D[(v0-1)*D_width+u0];
  }
  if(threadIdx.y == blockDim.y-1){
      D_shared[ut][vt+1] = D[(v0+1)*D_width+u0];
      D_shared[ut][vt+2] = D[(v0+2)*D_width+u0];
      D_shared[ut][vt+3] = D[(v0+3)*D_width+u0];
      //D_shared[ut][vt+4] = D[(v0+4)*D_width+u0];
  }

  if(D[idx] < 0){
      D_shared[ut][vt] = -10;
  }else{
      D_shared[ut][vt] = D[idx];
  }

  __syncthreads();

  // vertical filter
  // set pixel of interest
  val_curr = D_shared[ut][vt];

  weight_sum0 = 0;
  weight_sum = 0;
  factor_sum = 0;

  for(int32_t i=0; i < 8; i++){
    weight_sum0 = 4.0f - fabs(D_shared[ut][vt+(i-4)]-val_curr);
    weight_sum0 = max(0.0f, weight_sum0);
    weight_sum += weight_sum0;
    factor_sum += D_shared[ut][vt+(i-4)]*weight_sum0;
  }

  if (weight_sum>0) {
      float d = factor_sum/weight_sum;
      if (d>=0) *(D+idx) = d;
  }

}

// implements approximation to bilateral filtering
void ElasGPU::adaptiveMean (float* D) {
  
  // get disparity image dimensions
  int32_t D_width          = width;
  int32_t D_height         = height;
  if (param.subsampling) {
    D_width          = width/2;
    D_height         = height/2;
  }
  
  // allocate temporary memory
  float* D_copy = (float*)malloc(D_width*D_height*sizeof(float));
  float* D_tmp  = (float*)malloc(D_width*D_height*sizeof(float));
  memcpy(D_copy,D,D_width*D_height*sizeof(float));
  
  // zero input disparity maps to -10 (this makes the bilateral
  // weights of all valid disparities to 0 in this region)
  for (int32_t i=0; i<D_width*D_height; i++) {
    if (*(D+i)<0) {
      *(D_copy+i) = -10;
      *(D_tmp+i)  = -10;
    }
  }
  
  __m128 xconst0 = _mm_set1_ps(0);
  __m128 xconst4 = _mm_set1_ps(4.0f);
  __m128 xval,xweight1,xweight2,xfactor1,xfactor2;
  
  float *val     = (float *)_mm_malloc(8*sizeof(float),16);
  float *weight  = (float*)_mm_malloc(4*sizeof(float),16);
  float *factor  = (float*)_mm_malloc(4*sizeof(float),16);
  
  // set bitwise absolute value mask
  __m128 xabsmask = _mm_set1_ps(0x7FFFFFFF);
  
  // when doing subsampling: 4 pixel bilateral filter width
  if (param.subsampling) {
  
    // horizontal filter
    for (int32_t v=3; v<D_height-3; v++) {

      // init
      for (int32_t u=0; u<3; u++)
        val[u] = *(D_copy+v*D_width+u);

      // loop
      for (int32_t u=3; u<D_width; u++) {

        // set
        float val_curr = *(D_copy+v*D_width+(u-1));
        val[u%4] = *(D_copy+v*D_width+u);

        xval     = _mm_load_ps(val);      
        xweight1 = _mm_sub_ps(xval,_mm_set1_ps(val_curr));
        xweight1 = _mm_and_ps(xweight1,xabsmask);
        xweight1 = _mm_sub_ps(xconst4,xweight1);
        xweight1 = _mm_max_ps(xconst0,xweight1);
        xfactor1 = _mm_mul_ps(xval,xweight1);

        _mm_store_ps(weight,xweight1);
        _mm_store_ps(factor,xfactor1);

        float weight_sum = weight[0]+weight[1]+weight[2]+weight[3];
        float factor_sum = factor[0]+factor[1]+factor[2]+factor[3];
        
        if (weight_sum>0) {
          float d = factor_sum/weight_sum;
          if (d>=0) *(D_tmp+v*D_width+(u-1)) = d;
        }
      }
    }

    // vertical filter
    for (int32_t u=3; u<D_width-3; u++) {

      // init
      for (int32_t v=0; v<3; v++)
        val[v] = *(D_tmp+v*D_width+u);

      // loop
      for (int32_t v=3; v<D_height; v++) {

        // set
        float val_curr = *(D_tmp+(v-1)*D_width+u);
        val[v%4] = *(D_tmp+v*D_width+u);

        xval     = _mm_load_ps(val);      
        xweight1 = _mm_sub_ps(xval,_mm_set1_ps(val_curr));
        xweight1 = _mm_and_ps(xweight1,xabsmask);
        xweight1 = _mm_sub_ps(xconst4,xweight1);
        xweight1 = _mm_max_ps(xconst0,xweight1);
        xfactor1 = _mm_mul_ps(xval,xweight1);

        _mm_store_ps(weight,xweight1);
        _mm_store_ps(factor,xfactor1);

        float weight_sum = weight[0]+weight[1]+weight[2]+weight[3];
        float factor_sum = factor[0]+factor[1]+factor[2]+factor[3];
        
        if (weight_sum>0) {
          float d = factor_sum/weight_sum;
          if (d>=0) *(D+(v-1)*D_width+u) = d;
        }
      }
    }
    
  // full resolution: 8 pixel bilateral filter width
  // D(x) = sum(I(x)*f(I(xi)-I(x))*g(xi-x))/W(x)
  // W(x) = sum(f(I(xi)-I(x))*g(xi-x))
  // g(xi-x) = 1
  // f(I(xi)-I(x)) = 1-(I(xi)-I(x)) if greater than 0, 0 otherwise
  } else {
    
    // Calculate size of kernel
    int block_width = 8;
    int block_height = block_width;
    int grid_width, grid_height;

    //Calculate grid_size
    if((width-8)%block_width == 0) {
        grid_width = ceil(width/block_width);
    } else {
        grid_width = ceil(width/block_width); + 1;
    }

    if((height-8)%block_height == 0) {
        grid_height = ceil(height/block_height);
    } else {
        grid_height = ceil(height/block_height); + 1;
    }

     // Create size objects
    dim3 DimGrid(grid_width,grid_height,1);
    dim3 DimBlock(block_width,block_height,1);

    // CUDA copy over needed memory information
    // disparity_grid and respective copies
    float* d_D;

    // Allocate on global memory and copy
    cudaMalloc((void**) &d_D, width*height*sizeof(float));
    cudaMemcpy(d_D, D, width*height*sizeof(float), cudaMemcpyHostToDevice);

    //Kernel go!
    adaptiveMeanGPU8<<<DimGrid, DimBlock>>>(d_D, width, height);

    // Sync after the kernel is launched
    cudaDeviceSynchronize();

    // Copy the final disparity values back over
    cudaMemcpy(D, d_D, width*height*sizeof(float), cudaMemcpyDeviceToHost);

    //Free memory
    cudaFree(d_D);


    // horizontal filter
    /*for (int32_t v=3; v<D_height-3; v++) {

      // Preload first 7 pixels in row
      for (int32_t u=0; u<7; u++)
        val[u] = *(D_copy+v*D_width+u);

      // Loop through remainer of the row
      for (int32_t u=7; u<D_width; u++) {

        // Current pixel being filtered is middle of our set (4 back, in orginal its 3 for some reason)
        //Note this isn't truely the center since we have 8 for the vestor registers
        float val_curr = *(D_copy+v*D_width+(u-3));
        // Update the most outdated (farthest away) pixel of our 8
        val[u%8] = *(D_copy+v*D_width+u);

        float weight_sum0 = 0;
        float weight_sum2 = 0;
        float factor_sum2 = 0;

        for(int32_t i=0; i < 8; i++){
            weight_sum0 = 4.0f - std::fabs(val[i]-val_curr);
            weight_sum0 = std::fmax(0.0f, weight_sum0);
            weight_sum2 += weight_sum0;
            factor_sum2 += val[i]*weight_sum0;
        }

        if (weight_sum2>0) {
          float d = factor_sum2/weight_sum2;
          if (d>=0) *(D_tmp+v*D_width+(u-3)) = d;
        }
      }
    }
  
    // vertical filter
    for (int32_t u=3; u<D_width-3; u++) {

      // init
      for (int32_t v=0; v<7; v++)
        val[v] = *(D_tmp+v*D_width+u);

      // loop
      for (int32_t v=7; v<D_height; v++) {

        // set
        float val_curr = *(D_tmp+(v-3)*D_width+u);
        val[v%8] = *(D_tmp+v*D_width+u);

        float weight_sum0 = 0.0f;
        float weight_sum2 = 0.0f;
        float factor_sum2 = 0.0f;

        for(int32_t i=0; i < 8; i++){
            weight_sum0 = 4.0f - std::fabs(val[i]-val_curr);
            weight_sum0 = std::fmax(0.0f, weight_sum0);
            weight_sum2 += weight_sum0;
            factor_sum2 += val[i]*weight_sum0;
        }

        if (weight_sum2>0) {
          float d = factor_sum2/weight_sum2;
          if (d>=0) *(D+(v-3)*D_width+u) = d;
        }
      }
    }*/
  }
  
  // free memory
  _mm_free(val);
  _mm_free(weight);
  _mm_free(factor);
  free(D_copy);
  free(D_tmp);
}