#include <cuda.h>
#include <cufft.h>
#include "mex.h"
#include "gpu/mxGPUArray.h"
#include "common/helper_cuda.h"
#include "cudaConvFFTData.h"


const int N_MAX_PARALLEL = 32;
static bool debug = false;

/*
 * Device Code
 */

////////////////////////////////////////////////////////////////////////////////
// Pad data with zeros, 
////////////////////////////////////////////////////////////////////////////////
__global__ void padData(
    float *d_PaddedData,
    const float *d_Data,
    int fftW,
    int fftH,
    int dataW,
    int dataH,
    int FEATURE_DIM
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;
    const int z = IMUL(blockDim.z, blockIdx.z) + threadIdx.z;

    if(x < fftW && y < fftH && z < FEATURE_DIM){
        if(x < dataW && y < dataH)
            d_PaddedData[IMUL(z, IMUL(fftW, fftH)) + IMUL(x, fftH) + y] = 
                    d_Data[ IMUL(z, IMUL(dataH, dataW)) + IMUL(x, dataH ) + y];
        else
            d_PaddedData[IMUL(z, IMUL(fftW, fftH)) + IMUL(x, fftH) + y] = 0;
    }
}

////////////////////////////////////////////////////////////////////////////////
// Modulate Fourier image of padded data by Fourier image of padded kernel
// and normalize by FFT size
////////////////////////////////////////////////////////////////////////////////
__device__ void complexMulAndScale(cufftComplex &out, cufftComplex a, cufftComplex b, float c){
    const cufftComplex t = {c * (a.x * b.x - a.y * b.y), c * (a.y * b.x + a.x * b.y)};
    out = t;
}

__device__ void complexConjMulAndScale(cufftComplex &out, cufftComplex a, cufftComplex b, float c){
    const cufftComplex t = {c * (a.x * b.x + a.y * b.y), c * (a.y * b.x - a.x * b.y)};
    out = t;
}

__global__ void elementwiseProductAndNormalize(
    cufftComplex *fft_Output,
    const cufftComplex *fft_PaddedData,
    const cufftComplex *fft_PaddedKernel,
    int FFT_H,
    int FFT_W,
    int FEATURE_DIM,
    float scale
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;
    const int z = IMUL(blockDim.z, blockIdx.z) + threadIdx.z;
    
    if(x < FFT_W && y < FFT_H && z < FEATURE_DIM){
        // int i = IMUL(z, IMUL(FFT_W, FFT_H)) + IMUL(FFT_H, x) + y;
        int i = z * FFT_W * FFT_H + FFT_H * x + y;
        // complexConjMulAndScale(fft_Output[i], fft_PaddedData[i], fft_PaddedKernel[i], scale);
        fft_Output[i].x = scale * (fft_PaddedData[i].x * fft_PaddedKernel[i].x - fft_PaddedData[i].y * fft_PaddedKernel[i].y);
        fft_Output[i].y = scale * (fft_PaddedData[i].y * fft_PaddedKernel[i].x + fft_PaddedData[i].x * fft_PaddedKernel[i].y);
    }
}

/* Support in-place computation, i.e. input and output can be the same */
__global__ void sumAlongFeatures(
    float *convolutionResult,
    const float *convolutionPerFeature,
    int FFT_H,
    int FFT_W,
    int FEATURE_DIM
){
    const int x = IMUL(blockDim.x, blockIdx.x) + threadIdx.x;
    const int y = IMUL(blockDim.y, blockIdx.y) + threadIdx.y;

    if(x < FFT_W && y < FFT_H){
        const int result_i = IMUL(FFT_H, x) + y;
        const int N = IMUL(FFT_W, FFT_H);

        convolutionResult[result_i] = convolutionPerFeature[result_i];
        for (int z = 1; z < FEATURE_DIM; z++){
            convolutionResult[result_i] += 
                convolutionPerFeature[IMUL(z, N) + result_i];
        }
    }
}

/*
 * Host code
 */

////////////////////////////////////////////////////////////////////////////////
// Helper functions
////////////////////////////////////////////////////////////////////////////////
//Round a / b to nearest higher integer value
int iDivUp(int a, int b){
    return (a % b != 0) ? (a / b + 1) : (a / b);
}

//Align a to nearest higher multiple of b
int iAlignUp(int a, int b){
    return (a % b != 0) ?  (a - a % b + b) : a;
}


////////////////////////////////////////////////////////////////////////////////
// Mex Entry
////////////////////////////////////////////////////////////////////////////////
void mexFunction(int nlhs, mxArray *plhs[],
                 int nrhs, mxArray const *prhs[])
{
    ConvPlan plan[N_MAX_PARALLEL];

    /* Declare all variables.*/
    const mxGPUArray *mxFFTData;
    const mxGPUArray *mxKernel;
    mxGPUArray *mxFFTKernel;
    mxGPUArray *mxConvolution;
    mxArray *convolutionResult;
    
    /* cufftComplex is float2 */
    const cufftComplex *d_CFFT_DATA;
    cufftComplex *d_CFFT_KERNEL;
    cufftComplex *d_FFTEProd;

    float *d_CONVOLUTION;
    float *d_IFFTEProd;

    float *h_Kernel;
    float *h_CONVOLUTION;
    float *d_Kernel;
    float *d_PaddedKernel;

    /* concurrent kernel executions */
    int N_GPU; 
    int N_BATCH_PER_GPU = 4;

    char const * const errId = "parallel:gpu:mexGPUExample:InvalidInput";

    /* Choose a reasonably sized number of threads for the block. */
    int THREAD_PER_BLOCK_H = 16;
    int THREAD_PER_BLOCK_W = 8;
    int THREAD_PER_BLOCK_D = 8;
    int THREAD_PER_BLOCK_2D = 32;

    const mwSize * mxKernel_Dim;
    const mwSize * mxFFT_Dim;
    // int MblocksPerGrid, NblocksPerGrid;
    int KERNEL_H, KERNEL_W, N_KERNEL,
        CFFT_H, CFFT_W, FFT_H, FFT_W, FEATURE_DIM,
        KERNEL_SIZE, CFFT_SIZE, FFT_SIZE, CONV_SIZE;

    /* Initialize the MathWorks GPU API. */
    mxInitGPU();
    
    /* Throw an error if the input is not a GPU array. */
    if ( (nrhs < 2) || (nrhs > 3) || !mxIsGPUArray(prhs[0]) )
        mexErrMsgIdAndTxt(errId, "The data must be FFT-ed real array in GPU");

    if (( nrhs == 3)  && mxGetNumberOfElements(prhs[2]) != 4)
        mexErrMsgIdAndTxt(errId, "CUDA Thread Size must be 4 integers : THREAD_PER_BLOCK_H, THREAD_PER_BLOCK_W, THREAD_PER_BLOCK_D, THREAD_PER_BLOCK_2D\nYou must choose size such that total thread will not be larger than MaxThreadsPerBlock");

    if ( nrhs == 3 ){
        const double* threadSize = (double *)mxGetData(prhs[2]);
        THREAD_PER_BLOCK_H = (int)threadSize[0];
        THREAD_PER_BLOCK_W = (int)threadSize[1];
        THREAD_PER_BLOCK_D = (int)threadSize[2];
        THREAD_PER_BLOCK_2D = (int)threadSize[3];
        if(debug) fprintf(stderr,"Thread size: H=%d, W=%d, D=%d, 2D=%d\n", THREAD_PER_BLOCK_H, THREAD_PER_BLOCK_W, THREAD_PER_BLOCK_D, THREAD_PER_BLOCK_2D);
    }

    // cudaDeviceProp dev;
    // cudaGetDeviceProperties(&dev,0);
    // int success = checkDeviceProp(dev);

    mxFFTData = mxGPUCreateFromMxArray(prhs[0]);
    mxFFT_Dim = mxGPUGetDimensions(mxFFTData);

    // FFT Dim
    // In CUDA, R2C fft will create only N/2 + 1 points. This is due to the Hermitian symmetry of the points.
    CFFT_H = mxFFT_Dim[0];
    CFFT_W = mxFFT_Dim[1];

    FFT_H = (mxFFT_Dim[0] - 1) * 2;
    FFT_W = mxFFT_Dim[1];

    FEATURE_DIM = mxFFT_Dim[2];

    CFFT_SIZE = CFFT_W * CFFT_H * FEATURE_DIM * sizeof(float2);
    FFT_SIZE  = FFT_W  * FFT_H  * FEATURE_DIM * sizeof(float);
    CONV_SIZE = FFT_W  * FFT_H  * sizeof(float);
    
    if(debug) fprintf(stderr,"FFT Data size: h=%d, w=%d, f=%d\n", FFT_H, FFT_W, FEATURE_DIM);

    if (mxGetClassID(prhs[1]) != mxCELL_CLASS)
        mexErrMsgIdAndTxt(errId, "Kernel must be a cell array");

    mwSize nKernel = mxGetNumberOfElements(prhs[1]);
    N_KERNEL = (int)nKernel;
    plhs[0] = mxCreateCellMatrix(1, N_KERNEL);

    if(debug) fprintf(stderr,"N Kernel: %d\n", N_KERNEL);


    /* Set block size and thread size */
    dim3 threadBlock3D(THREAD_PER_BLOCK_H, THREAD_PER_BLOCK_W, THREAD_PER_BLOCK_D);
    dim3 dataBlockGrid3D( iDivUp(FFT_W, threadBlock3D.x), 
                        iDivUp(FFT_H, threadBlock3D.y), 
                        iDivUp(FEATURE_DIM, threadBlock3D.z));

    dim3 threadBlock2D( THREAD_PER_BLOCK_2D, THREAD_PER_BLOCK_2D);
    dim3 dataBlockGrid2D( iDivUp(FFT_W, threadBlock2D.x), 
                        iDivUp(FFT_H, threadBlock2D.y));


    /* Find number of cuda capable devices */
    checkCudaErrors(cudaGetDeviceCount(&N_GPU));
    if(debug) fprintf(stderr, "CUDA-capable device count: %i\n", N_GPU);


    /*  Pad Kernel */
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_PaddedKernel,    FFT_SIZE));
    CUDA_SAFE_CALL(cudaMalloc((void **)&d_IFFTEProd,       FFT_SIZE));

    /* Create a GPUArray to hold the result and get its underlying pointer. */
    // mwSize *FFT_dims = (mwSize *)mxMalloc(2 * sizeof(mwSize));
    // FFT_dims[0] = FFT_H;
    // FFT_dims[1] = FFT_W;
    // FFT_dims[2] = FEATURE_DIM;

    d_CFFT_DATA = (cufftComplex *)mxGPUGetDataReadOnly(mxFFTData);

    // mxConvolution = mxGPUCreateGPUArray(2,
    //                         FFT_dims, // Third element will not be accessed
    //                         mxSINGLE_CLASS,
    //                         mxREAL,
    //                         MX_GPU_DO_NOT_INITIALIZE);

    // d_CONVOLUTION = (cufftReal *)(mxGPUGetData(mxConvolution));

    CUDA_SAFE_CALL(cudaMalloc((void **)&d_CONVOLUTION, CONV_SIZE));

    // mxFFTKernel = mxGPUCreateGPUArray(3,
    //                         mxFFT_Dim,
    //                         mxSINGLE_CLASS,
    //                         mxCOMPLEX,
    //                         MX_GPU_DO_NOT_INITIALIZE);

    // d_CFFT_KERNEL = (cufftComplex *)(mxGPUGetData(mxFFTKernel));

    CUDA_SAFE_CALL(cudaMalloc((void **)&d_CFFT_KERNEL, CFFT_SIZE));

    CUDA_SAFE_CALL(cudaMalloc((void **)&d_FFTEProd, CFFT_SIZE));

    /* FFT Kernel */
    int BATCH = FEATURE_DIM;
    int FFT_Dims[] = { FFT_W, FFT_H };
    int CFFT_Dims[] = { CFFT_W, CFFT_H };

    int idist = FFT_W * FFT_H;
    int odist = CFFT_W * CFFT_H;

    cufftHandle FFTplan_R2C, FFTplan_C2R;
    CUFFT_SAFE_CALL(cufftPlanMany(&FFTplan_R2C, 
        2, // rank
        FFT_Dims, 
        FFT_Dims, 1, idist, // *inembed, istride, idist
        CFFT_Dims, 1, odist, // *onembed, ostride, odist
        CUFFT_R2C, 
        BATCH)); // batch

    CUFFT_SAFE_CALL(cufftPlanMany(&FFTplan_C2R, 
        2, // rank
        FFT_Dims,
        CFFT_Dims, 1, odist, // *inembed, istride, idist
        FFT_Dims, 1, idist, // *onembed, ostride, odist
        CUFFT_C2R, 
        BATCH)); // batch
    
    mwSize *FFT_dims = (mwSize *)mxMalloc(2 * sizeof(mwSize));
        FFT_dims[0] = FFT_H;
        FFT_dims[1] = FFT_W;

    /* For each kernel iterate */
    for (int kernelIdx = 0; kernelIdx < N_KERNEL; kernelIdx++){
        
        // Get Kernel Data
        const mxArray *mxCurrentCell = mxGetCell(prhs[1], kernelIdx);
        if (!mxIsGPUArray(mxCurrentCell)){
            
            if( mxGetClassID(mxCurrentCell) != mxSINGLE_CLASS || mxGetNumberOfDimensions(mxCurrentCell) != 3 )
                mexErrMsgIdAndTxt(errId, "Kernels must be of type float and have features larger than 1");

            h_Kernel = (float *)mxGetData(mxCurrentCell);
            mxKernel_Dim = mxGetDimensions(mxCurrentCell);

            // Kernel dimensions
            KERNEL_H = mxKernel_Dim[0];
            KERNEL_W = mxKernel_Dim[1];
            KERNEL_SIZE = KERNEL_W * KERNEL_H * FEATURE_DIM * sizeof(float);

            CUDA_SAFE_CALL(cudaMalloc((void **)&d_Kernel, KERNEL_SIZE));
            CUDA_SAFE_CALL(cudaMemcpy(d_Kernel, h_Kernel, KERNEL_SIZE, cudaMemcpyHostToDevice));
            mxKernel = NULL;
        }else{ // Kernel is GPU Array
            mxKernel = mxGPUCreateFromMxArray(mxCurrentCell);

            if ( mxGPUGetClassID(mxKernel) != mxSINGLE_CLASS || mxGPUGetNumberOfDimensions(mxKernel) != 3 )
                mexErrMsgIdAndTxt(errId, "Kernels must be of type float and have features larger than 1");

            mxKernel_Dim = mxGPUGetDimensions(mxKernel);

            // Kernel dimensions
            KERNEL_H = mxKernel_Dim[0];
            KERNEL_W = mxKernel_Dim[1];
            KERNEL_SIZE = KERNEL_W * KERNEL_H * FEATURE_DIM * sizeof(float);

            d_Kernel = (float *)mxGPUGetDataReadOnly(mxKernel);
        }

        if(debug) fprintf(stderr,"Kernel size: h=%d, w=%d\n", KERNEL_H, KERNEL_W);

        if (FEATURE_DIM != mxKernel_Dim[2] || KERNEL_W > FFT_W || KERNEL_H > FFT_H ){
            mexErrMsgIdAndTxt(errId, "Kernel and Data must have the same number of features and kernel size should be smaller than data size");
        }

        padData<<<dataBlockGrid3D, threadBlock3D>>>(
            d_PaddedKernel,
            d_Kernel,
            FFT_W,
            FFT_H,
            KERNEL_W,
            KERNEL_H,
            FEATURE_DIM
            );


        CUFFT_SAFE_CALL(cufftExecR2C(FFTplan_R2C, d_PaddedKernel, d_CFFT_KERNEL));
        CUDA_SAFE_CALL(cudaDeviceSynchronize());

        if(debug) fprintf(stderr,"FFT done\n");

        
        /* Hadamard product, Element-wise multiplication in frequency domain */
        /* If execute the following, second compile of this file create MATLAB error */
        elementwiseProductAndNormalize<<<dataBlockGrid3D, threadBlock3D>>>(
                d_FFTEProd, // out
                d_CFFT_DATA, // in data
                d_CFFT_KERNEL,   // in kernel
                CFFT_H,
                CFFT_W,
                FEATURE_DIM,
                1.0f / (FFT_W * FFT_H)
            );

        CUFFT_SAFE_CALL(cufftExecC2R(FFTplan_C2R, d_FFTEProd, d_IFFTEProd));
        CUDA_SAFE_CALL(cudaDeviceSynchronize());

        sumAlongFeatures<<<dataBlockGrid2D, threadBlock2D>>>(
                d_CONVOLUTION,
                d_IFFTEProd,
                FFT_H,
                FFT_W,
                FEATURE_DIM
            );



        convolutionResult = mxCreateNumericArray(2, FFT_dims, mxSINGLE_CLASS, mxREAL);
        h_CONVOLUTION = (float *)mxGetData(convolutionResult);
        CUDA_SAFE_CALL(cudaMemcpy(h_CONVOLUTION, d_CONVOLUTION, CONV_SIZE ,cudaMemcpyDeviceToHost));

        mxSetCell(plhs[0], kernelIdx, convolutionResult);
    }
    // plhs[1] = mxGPUCreateMxArrayOnGPU(mxFFTKernel);

    /*
     * The mxGPUArray pointers are host-side structures that refer to device
     * data. These must be destroyed before leaving the MEX function.
     */
    mxGPUDestroyGPUArray(mxFFTData);
    // mxGPUDestroyGPUArray(mxConvolution);    
    // mxGPUDestroyGPUArray(mxFFTKernel);
    
    cufftDestroy(FFTplan_R2C);
    cufftDestroy(FFTplan_C2R);

    if(mxKernel == NULL) mxGPUDestroyGPUArray(mxKernel);

    cudaFree(d_PaddedKernel);
    cudaFree(d_IFFTEProd);
    cudaFree(d_CONVOLUTION);
    cudaFree(d_CFFT_KERNEL);
    cudaFree(d_FFTEProd);
    
    if(mxKernel == NULL) cudaFree(d_Kernel);

    mxFree(FFT_dims);
}
