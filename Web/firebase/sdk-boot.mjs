// Registers the SDK resolve hook before the checks load anything.
//
// A resolve hook has to be in place before the module graph is loaded, which
// is what `--import` guarantees and a plain import inside the check would not.

import { register } from 'node:module';

register('./sdk-hooks.mjs', import.meta.url);
