#include "PReLUExecution.hpp"
#include "MNNCUDADefine.hpp"
namespace MNN {
namespace CUDA {
#define CUDA_KERNEL_LOOP(i, n) for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < (n); i += blockDim.x * gridDim.x)

template<typename T>
__global__ void PRELU(const int n, const int channels, const int dim, const T* in, T* out,
                        const float* slopeData, int div_factor) {
    CUDA_KERNEL_LOOP(t, n) {
        int index = t / PACK_NUMBER;
        int r = t % PACK_NUMBER;
        int c      = (index / dim) % channels / div_factor;
        float iv = (float)in[t];
        float ov = iv > 0.0 ? iv : iv * slopeData[c * PACK_NUMBER + r];
        out[t] = (T)ov;
    }
}

PReLUExecution::PReLUExecution(const PRelu* prelu, Backend *backend) : Execution(backend) {
    int slopCount = prelu->slope()->size();
    auto alphaData = prelu->slope()->data();
    auto staticPool = static_cast<CUDABackend*>(backend)->getStaticBufferPool();
    auto slopeSize = UP_DIV(slopCount, PACK_NUMBER) * PACK_NUMBER * sizeof(float);
    mPreluStorage = staticPool->alloc(slopeSize);
    mDeviceSlope = (uint8_t*)mPreluStorage.first + mPreluStorage.second;

    MNN_ASSERT(nullptr != mDeviceSlope);
    cudaMemset(mDeviceSlope, 0, slopeSize);
    cudaMemcpy(mDeviceSlope, alphaData, slopCount * sizeof(float), cudaMemcpyHostToDevice);
    mIsChannelShared = slopCount == 1;
}
PReLUExecution::~PReLUExecution() {
    auto staticPool = static_cast<CUDABackend*>(backend())->getStaticBufferPool();
    staticPool->free(mPreluStorage);
}

ErrorCode PReLUExecution::onResize(const std::vector<Tensor *> &inputs, const std::vector<Tensor *> &outputs) {
    MNN_ASSERT(inputs.size() == 1);
    MNN_ASSERT(outputs.size() == 1);
    auto input = inputs[0];
    MNN_ASSERT(input->dimensions() >= 2);
    mArea      = input->length(0);
    for (int i = 2; i < input->dimensions(); ++i) {
        mArea *= input->length(i);
    }
    mChannel = UP_DIV(input->length(1), PACK_NUMBER);
    mCount = mChannel*mArea * PACK_NUMBER;
    //printf("mBatch:%d- mChannel:%d- mArea:%d- mCount:%d\n", mBatch,mChannel,mArea, mCount);
    return NO_ERROR;
}

ErrorCode PReLUExecution::onExecute(const std::vector<Tensor *> &inputs, const std::vector<Tensor *> &outputs) {
    auto runtime = static_cast<CUDABackend*>(backend())->getCUDARuntime();
    auto bytes = static_cast<CUDABackend*>(backend())->getBytes(inputs[0]);
 
    int block_num = runtime->blocks_num(mCount);
    int threads_num = runtime->threads_num();
    auto input_addr = (void*)inputs[0]->deviceId();
    auto output_addr = (void*)outputs[0]->deviceId();
    int div_factor = mIsChannelShared ? mChannel : 1;
    if (2 == bytes) {
        PRELU<<<block_num, threads_num>>>(mCount, mChannel, mArea, (const half *)input_addr, (half *)output_addr,
            (const float *)mDeviceSlope, div_factor);
    } else {
        PRELU<<<block_num, threads_num>>>(mCount, mChannel, mArea, (const float *)input_addr, (float *)output_addr,
            (const float *)mDeviceSlope, div_factor);
    }
    return NO_ERROR;
}

class PReLUCreator : public CUDABackend::Creator {
public:
    virtual Execution* onCreate(const std::vector<Tensor*>& inputs, const std::vector<Tensor*>& outputs,
                                const MNN::Op* op, Backend* backend) const override {
        auto param = op->main_as_PRelu();
        return new PReLUExecution(param, backend);
    }
};

static CUDACreatorRegister<PReLUCreator> __init(OpType_PReLU);

}
}