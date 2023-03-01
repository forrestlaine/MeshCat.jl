abstract type AbstractCommand end

struct SetObject{O <: AbstractObject} <: AbstractCommand
    object::O
    path::Path
end

struct SetTransform{T <: Transformation} <: AbstractCommand
    tform::T
    path::Path
end

struct Delete <: AbstractCommand
    path::Path
end

struct SetProperty{T} <: AbstractCommand
    path::Path
    property::String
    value::T
end

struct SetAnimation{A <: Animation} <: AbstractCommand
    animation::A
    play::Bool
    repetitions::Int
end

struct SetCameraTarget{T <: Real} <: AbstractCommand
    value::AbstractVector{T}
end

SetAnimation(anim::Animation; play=true, repetitions=1) = SetAnimation(anim, play, repetitions)

struct SaveImage <: AbstractCommand end
