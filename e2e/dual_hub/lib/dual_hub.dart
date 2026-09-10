// Minimal library body for the two dual-hub targets.
//
// Deliberately importing nothing: what is under test is which `clock` and
// `path` records reach the consuming library's package closure, and importing
// either would add a compile-time dependency on their APIs to a workspace whose
// point is the package graph rather than the code.
const dualHub = 'dual_hub';
