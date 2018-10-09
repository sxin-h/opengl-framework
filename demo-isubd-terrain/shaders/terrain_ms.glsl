#line 2

#define USE_OPTIMIZED_TASK_PARAMETER_BLOCK          1

#define NUM_CLIPPING_PLANES                         6

#define MeshPatchAttributes() vec4 vertices[3]; uint key; 


////////////////////////////////////////////////////////////////////////////////
// Implicit Subdivition Sahder for Terrain Rendering
//

layout(std430, binding = BUFFER_BINDING_SUBD1)
readonly buffer SubdBufferIn {
    uvec2 u_SubdBufferIn[];
};

layout(std430, binding = BUFFER_BINDING_SUBD2)
buffer SubdBufferOut {
    uvec2 u_SubdBufferOut[];
};

layout(std430, binding = BUFFER_BINDING_GEOMETRY_VERTICES)
readonly buffer VertexBuffer {
    vec4 u_VertexBuffer[];
};

layout(std430, binding = BUFFER_BINDING_GEOMETRY_INDEXES)
readonly buffer IndexBuffer {
    uint u_IndexBuffer[];
};

layout(std430, binding = BUFFER_BINDING_INSTANCED_GEOMETRY_VERTICES)
readonly buffer VertexBufferInstanced {
    vec2 u_VertexBufferInstanced[];
};

layout(std430, binding = BUFFER_BINDING_INSTANCED_GEOMETRY_INDEXES)
readonly buffer IndexBufferInstanced {
    uint16_t u_IndexBufferInstanced[];
};


layout(binding = BUFFER_BINDING_SUBD_COUNTER)
uniform atomic_uint u_SubdBufferCounter;


layout(std430, binding = BUFFER_BINDING_INDIRECT_COMMAND)
buffer IndirectCommandBuffer {
    uint u_IndirectCommand[8];
};


struct Transform {
    mat4 modelView;
    mat4 projection;
    mat4 modelViewProjection;
    mat4 viewInv;
};

layout(std140, row_major, binding = BUFFER_BINDING_TRANSFORMS)
uniform Transforms{
    Transform u_Transform;
};

uniform sampler2D u_DmapSampler; // displacement map
uniform sampler2D u_SmapSampler; // slope map
uniform float u_DmapFactor;
uniform float u_LodFactor;


vec2 intValToColor2(int keyLod) {
    keyLod = keyLod % 64;

    int bx = (keyLod & 0x1) | ((keyLod >> 1) & 0x2) | ((keyLod >> 2) & 0x4);
    int by = ((keyLod >> 1) & 0x1) | ((keyLod >> 2) & 0x2) | ((keyLod >> 3) & 0x4);

    return vec2(float(bx) / 7.0f, float(by) / 7.0f);
}

// displacement map
float dmap(vec2 pos)
{
#if 0
    return cos(20.0 * pos.x) * cos(20.0 * pos.y) / 2.0 * u_DmapFactor;
#else
    return (texture(u_DmapSampler, pos * 0.5 + 0.5).x) * u_DmapFactor;
#endif
}

float distanceToLod(float z, float lodFactor)
{
    // Note that we multiply the result by two because the triangle's
    // edge lengths decreases by half every two subdivision steps.
    return -2.0 * log2(clamp(z * lodFactor, 0.0f, 1.0f));
}



// -----------------------------------------------------------------------------
/**
 * Task Shader
 *
 * This task shader is responsible for updating the
 * subdivision buffer and sending visible geometry to the mesh shader.
 */
#ifdef TASK_SHADER
layout(local_size_x = COMPUTE_THREAD_COUNT) in;

#if USE_OPTIMIZED_TASK_PARAMETER_BLOCK == 0
taskNV out Patch{
    MeshPatchAttributes()
} o_Patch[COMPUTE_THREAD_COUNT];
#else
taskNV out Patch{
    vec4 vertices[3 * COMPUTE_THREAD_COUNT];
} o_Patch;
#endif


float computeLod(vec3 c)
{
#if FLAG_DISPLACE
    c.z += dmap(u_Transform.viewInv[3].xy);
#endif

    vec4 cxf4 = (u_Transform.modelView * vec4(c, 1));
    vec3 cxf = cxf4.xyz;
    float z = length(cxf);

    return distanceToLod(z, u_LodFactor);
}

float computeLod(in vec4 v[3])
{
    vec3 c = (v[1].xyz + v[2].xyz) / 2.0;
    return computeLod(c);
}
float computeLod(in vec3 v[3])
{
    vec3 c = (v[1].xyz + v[2].xyz) / 2.0;
    return computeLod(c);
}

void writeKey(uint primID, uint key)
{
    uint idx = atomicCounterIncrement(u_SubdBufferCounter);

    u_SubdBufferOut[idx] = uvec2(primID, key);
}


void updateSubdBuffer(uint primID, uint key, int targetLod, int parentLod)
{
    // extract subdivision level associated to the key
    int keyLod = findMSB(key);

    // update the key accordingly
    if (/* subdivide ? */ keyLod < targetLod && !isLeafKey(key)) {
        uint children[2]; childrenKeys(key, children);

        writeKey(primID, children[0]);
        writeKey(primID, children[1]);
    } else if (/* keep ? */ keyLod < (parentLod + 1)) {
        writeKey(primID, key);
    } else /* merge ? */ {

        if (/* is root ? */isRootKey(key))
        {
            writeKey(primID, key);
        }
#if 1
        else if (/* is zero child ? */isChildZeroKey(key)) {
            writeKey(primID, parentKey(key));
        }
#else
        //Experiments to fix missing triangles when merging
        else {
            int numMergeLevels = keyLod - (parentLod);

            uint mergeMask = (key & ((1 << numMergeLevels) - 1));
            if (mergeMask == 0)
            {
                key = (key >> numMergeLevels);
                writeKey(primID, key);
            }

        }
#endif
    }
}

void main()
{

    // get threadID (each key is associated to a thread)
    uint threadID = gl_GlobalInvocationID.x;

    bool isVisible = true;

    uint key; vec3 v[3];

    // early abort if the threadID exceeds the size of the subdivision buffer
    if (threadID >= u_IndirectCommand[7]) {   //Num triangles is stored in the last reserved field of the draw indiretc structure

        isVisible = false;

    } else {

        // get coarse triangle associated to the key
        uint primID = u_SubdBufferIn[threadID].x;
        vec3 v_in[3] = vec3[3](
            u_VertexBuffer[u_IndexBuffer[primID * 3]].xyz,
            u_VertexBuffer[u_IndexBuffer[primID * 3 + 1]].xyz,
            u_VertexBuffer[u_IndexBuffer[primID * 3 + 2]].xyz
            );

        // compute distance-based LOD
        key = u_SubdBufferIn[threadID].y;
        vec3 vp[3]; subd(key, v_in, v, vp);
        int targetLod = int(computeLod(v));
        int parentLod = int(computeLod(vp));
#if FLAG_FREEZE
        targetLod = parentLod = findMSB(key);
#endif
        updateSubdBuffer(primID, key, targetLod, parentLod);


#if FLAG_CULL
        // Cull invisible nodes
        mat4 mvp = u_Transform.modelViewProjection;
        vec3 bmin = min(min(v[0], v[1]), v[2]);
        vec3 bmax = max(max(v[0], v[1]), v[2]);

        // account for displacement in bound computations
#   if FLAG_DISPLACE
        bmin.z = 0;
        bmax.z = u_DmapFactor;
#   endif

        isVisible = frustumCullingTest(mvp, bmin.xyz, bmax.xyz);
#endif // FLAG_CULL

    }


    uint laneID = gl_LocalInvocationID.x;
    uint voteVisible = ballotThreadNV(isVisible);
    uint numTasks = bitCount(voteVisible);

    if (laneID == 0) {
        gl_TaskCountNV = numTasks;
    }


    if (isVisible) {
        uint idxOffset = bitCount(voteVisible & gl_ThreadLtMaskNV);

        // set output data
        //o_Patch[idxOffset].vertices = v;
#if USE_OPTIMIZED_TASK_PARAMETER_BLOCK == 0
        o_Patch[idxOffset].vertices = vec4[3](vec4(v[0], 1.0), vec4(v[1], 1.0), vec4(v[2], 1.0));
        o_Patch[idxOffset].key = key;
#else
        o_Patch.vertices[idxOffset * 3 + 0] = vec4(v[0].xyz, v[1].x);
        o_Patch.vertices[idxOffset * 3 + 1] = vec4(v[1].yz, v[2].xy);
        o_Patch.vertices[idxOffset * 3 + 2] = vec4(v[2].z, uintBitsToFloat(key), 0.0, 0.0);
#endif

    }

}
#endif

// -----------------------------------------------------------------------------
/**
 * Mesh Shader
 *
 * This mesh shader is responsible for placing the
 * geometry properly on the input mesh (here a terrain).
 */
#ifdef MESH_SHADER

const int gpuSubd = PATCH_SUBD_LEVEL;

layout(local_size_x = COMPUTE_THREAD_COUNT) in;
layout(max_vertices = INSTANCED_MESH_VERTEX_COUNT, max_primitives = INSTANCED_MESH_PRIMITIVE_COUNT) out;
layout(triangles) out;

#if USE_OPTIMIZED_TASK_PARAMETER_BLOCK == 0
taskNV in Patch{
    MeshPatchAttributes()
} i_Patch[COMPUTE_THREAD_COUNT];
#else
taskNV in Patch{
    vec4 vertices[3 * COMPUTE_THREAD_COUNT];
} i_Patch;
#endif


layout(location = 0) out Interpolants{
    vec2 o_TexCoord;
} OUT[INSTANCED_MESH_VERTEX_COUNT];

void main()
{

    int id = int(gl_WorkGroupID.x);
    uint laneID = gl_LocalInvocationID.x;


    //Multi-threads, *load* instanced geom
#if USE_OPTIMIZED_TASK_PARAMETER_BLOCK == 0
    vec3 v[3] = vec3[3](
        i_Patch[id].vertices[0].xyz,
        i_Patch[id].vertices[1].xyz,
        i_Patch[id].vertices[2].xyz
        );

    uint key = i_Patch[id].key;
#else
    vec3 v[3] = vec3[3](
        i_Patch.vertices[id * 3 + 0].xyz,
        vec3(i_Patch.vertices[id * 3 + 0].w, i_Patch.vertices[id * 3 + 1].xy),
        vec3(i_Patch.vertices[id * 3 + 1].zw, i_Patch.vertices[id * 3 + 2].x)
        );

    uint key = floatBitsToUint(i_Patch.vertices[id * 3 + 2].y);
#endif


    const int vertexCnt = INSTANCED_MESH_VERTEX_COUNT;
    const int triangleCnt = INSTANCED_MESH_PRIMITIVE_COUNT;
    const int indexCnt = triangleCnt * 3;

    gl_PrimitiveCountNV = triangleCnt;


    int numLoop = (vertexCnt % COMPUTE_THREAD_COUNT) != 0 ? (vertexCnt / COMPUTE_THREAD_COUNT) + 1 : (vertexCnt / COMPUTE_THREAD_COUNT);
    for (int l = 0; l < numLoop; ++l) {
        int curVert = int(laneID) + l * COMPUTE_THREAD_COUNT;

        if (curVert < vertexCnt) {

            vec2 instancedBaryCoords = u_VertexBufferInstanced[curVert];

            vec3 finalVertex = berp(v, instancedBaryCoords);



#if FLAG_DISPLACE
            finalVertex.z += dmap(finalVertex.xy);
#endif
#if SHADING_LOD
            //vec2 tessCoord = instancedBaryCoords;
            int keyLod = findMSB(key);


            vec2 tessCoord = intValToColor2(keyLod);
            //vec2 tessCoord = intValToColor2(int(gl_WorkGroupID.x));
            //vec2 tessCoord = intValToColor2( int(i_Patch[id].taskId) );
#else
            vec2 tessCoord = finalVertex.xy * 0.5 + 0.5;
#endif

            OUT[curVert].o_TexCoord = tessCoord;
            gl_MeshVerticesNV[curVert].gl_Position = u_Transform.modelViewProjection * vec4(finalVertex, 1.0);
            for (int d = 0; d < NUM_CLIPPING_PLANES; d++) {
                gl_MeshVerticesNV[curVert].gl_ClipDistance[d] = 1.0;
            }
        }

    }


    int numLoopIdx = (indexCnt % COMPUTE_THREAD_COUNT) != 0 ? (indexCnt / COMPUTE_THREAD_COUNT) + 1 : (indexCnt / COMPUTE_THREAD_COUNT);
    for (int l = 0; l < numLoopIdx; ++l) {
        int curIdx = int(laneID) + l * COMPUTE_THREAD_COUNT;

        if (curIdx < indexCnt) {
            uint indexVal = u_IndexBufferInstanced[curIdx];

            gl_PrimitiveIndicesNV[curIdx] = indexVal;
        }

    }

}
#endif

// -----------------------------------------------------------------------------
/**
 * Fragment Shader
 *
 * This fragment shader is responsible for shading the final geometry.
 */
#ifdef FRAGMENT_SHADER
 //layout(location = 0) in vec2 i_TexCoord;
layout(location = 0) in Interpolants{
    vec2 o_TexCoord;
} IN;

layout(location = 0) out vec4 o_FragColor;

void main()
{
    vec2 i_TexCoord = IN.o_TexCoord;
#if SHADING_LOD
    vec3 c[3] = vec3[3](vec3(0.0, 0.25, 0.25),
        vec3(0.86, 0.00, 0.00),
        vec3(1.0, 0.50, 0.00));
    vec3 color = berp(c, i_TexCoord);
    o_FragColor = vec4(color, 1);
    //o_FragColor = vec4(i_TexCoord,0, 1);
#elif SHADING_DIFFUSE
    vec2 s = texture(u_SmapSampler, i_TexCoord).rg * u_DmapFactor;
    vec3 n = normalize(vec3(-s, 1));
    float d = clamp(n.z, 0.0, 1.0);

    o_FragColor = vec4(vec3(d / 3.14159), 1);

#elif SHADING_NORMALS
    vec2 s = texture(u_SmapSampler, i_TexCoord).rg * u_DmapFactor;
    vec3 n = normalize(vec3(-s, 1));

    o_FragColor = vec4(abs(n), 1);

#else
    o_FragColor = vec4(1, 0, 0, 1);
#endif

}

#endif
