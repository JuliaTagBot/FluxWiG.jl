module FluxMNIST

using Flux, Flux.Data.MNIST, Statistics
using Flux: onehotbatch, onecold, crossentropy, throttle, @epochs
import Flux: glorot_uniform
using FluxWiG
using Base.Iterators: repeated, partition
using BSON: @save
using Dates
# using CuArrays

include("util.jl")

#=
Initialization is from
He et al., 2015,
Delving Deep into Rectifiers: Surpassing Human-Level Performance on ImageNet Classification
https://arxiv.org/abs/1502.01852
=#
kaiming(::Type{T}, h, w, i, o) where {T<:AbstractFloat} = T(sqrt(2 / (w * h * o))) .* randn(T, h, w, i, o)
glorot_uniform(::Type{T}, dims...) where {T<:AbstractFloat} = (rand(T, dims...) .- T(0.5)) .* sqrt(T(24.0)/(sum(dims)))

# Classify MNIST digits with a convolutional network
function loadMNIST(::Type{T}, batch_size::Int = 1000) where {T<:AbstractFloat}
    imgs = MNIST.images()

    labels = onehotbatch(MNIST.labels(), 0:9)

    _train = BatchProducer(T.(cat((cat(float.(imgs[idxs])..., dims = 4)
                                   for idxs in partition(1:60_000, batch_size))..., dims=4)),
                           labels, batch_size, true)
    train = (gpu.(minibatch) for minibatch in _train)

    # Prepare test set (first 1,000 images)
    tX = T.(cat(float.(MNIST.images(:test)[1:batch_size])..., dims = 4)) |> gpu
    tY = onehotbatch(MNIST.labels(:test)[1:batch_size], 0:9) |> gpu

    return (train, tX, tY)
end

# for Float32 and kaiming initialization
(::Type{Conv})(::Type{T}, k::NTuple{N,Integer}, ch::Pair{<:Integer,<:Integer}, σ = identity;
        init = kaiming, stride = 1, pad = 0, dilation = 1) where {T<:AbstractFloat, N} =
    Conv(param(init(T, k..., ch...)), param(zeros(T, ch[2])), σ, stride = stride, pad = pad, dilation = dilation)

function (::Type{Dense})(::Type{T}, in::Integer, out::Integer, σ = identity;
        initW = glorot_uniform, initb = zeros) where {T<:AbstractFloat}
    return Dense(param(initW(T, out, in)), param(initb(T, out)), σ)
end

# Model
mutable struct Model{T,M}
    m::M
    (::Type{Model{T}})() where {T<:AbstractFloat} = new{T,Chain}(Chain(
        Conv(T, (5, 5), 1=>32),
        WiG{T,Conv}((3, 3, 32)),
        x -> maxpool(x, (2, 2)),
        Conv(T, (5, 5), 32=>64),
        WiG{T,Conv}((3, 3, 64)),
        x -> maxpool(x, (2, 2)),
        x -> reshape(x, :, size(x, 4)),
        Dense(T, 1024, 1024),
        WiG{T,Dense}(1024),
        Dropout(0.5),
        Dense(T, 1024, 10),
        softmax) |> gpu
    )
end

# loss(x, y) = crossentropy(m(x), y)
mutable struct Loss{M} <: Function
    m::M
end
(loss::Loss)(x, y) = crossentropy(loss.m(x), y)

# accuracy(x, y) = mean(onecold(m(x)) .== onecold(y))
mutable struct Accuracy{M} <:Function
    m::M
end
(accuracy::Accuracy)(x, y) = mean(onecold(accuracy.m(x)) .== onecold(y))

# train!
function train!(m::Model, traindata; epochs = 10, cb = identity)
    loss = Loss(m.m)
    opt = ADAM(params(m.m))  # TODO: patameterize
    @epochs epochs Flux.train!(loss, traindata, opt; cb=cb)
end

# save Model (weights only)
function savemodel(m::Model{Float32})
    ts = Dates.format(now(), dateformat"yyyymmddHHMMSS")
    savemodel(m, "model-fluxwig-f32_$(ts).bson")
end
function savemodel(m::Model)
    ts = Dates.format(now(), dateformat"yyyymmddHHMMSS")
    savemodel(m, "model-fluxwig-f64_$(ts).bson")
end
function savemodel(m::Model, filename::AbstractString)
    weights = Tracker.data.(params(m.m))
    @save filename weights
end

end # module
