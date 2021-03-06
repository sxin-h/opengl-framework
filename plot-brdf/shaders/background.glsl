// --------------------------------------------------
// Uniforms
// --------------------------------------------------
uniform vec3 u_ClearColor;

struct Transform {
	mat4 modelView;
	mat4 projection;
	mat4 modelViewProjection;
	mat4 viewInv;
};

layout(std140, row_major, binding = BUFFER_BINDING_TRANSFORMS)
uniform Transforms {
	Transform u_Transform;
};

// --------------------------------------------------
// Vertex shader
// --------------------------------------------------
#ifdef VERTEX_SHADER
layout(location = 0) out vec3 o_TexCoord;
void main() {
	// draw a full screen quad in modelview space
	vec2 p = vec2(gl_VertexID & 1, gl_VertexID >> 1 & 1) * 2.0 - 1.0;
	vec3 e = vec3(-900.0, p * 1e5);

	gl_Position = u_Transform.projection * vec4(e, 1);
	gl_Position.z = 0.99999 * gl_Position.w; // make sure the cubemap is visible
	o_TexCoord = vec3(u_Transform.viewInv * vec4(normalize(e), 0));
}
#endif

// --------------------------------------------------
// Fragment shader
// --------------------------------------------------
#ifdef FRAGMENT_SHADER
layout(location = 0) in vec3 i_TexCoord;
layout(location = 0) out vec4 o_FragColor;

void main() {
	o_FragColor = vec4(1);
}
#endif


