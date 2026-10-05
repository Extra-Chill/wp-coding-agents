<?php
// Boundary fixture: registry layer selection and explicit user scoping. A
// live read against the installed WordPress follows before local activation.
namespace DataMachine\Engine\AI {
    class MemoryFileRegistry {
        const MODE_ALL='all', INJECTION_AGENT_IDENTITY='identity', INJECTION_AGENT_MEMORY='memory', INJECTION_USER_PROFILE='user', LAYER_AGENT='agent', LAYER_USER='user', LAYER_PRINCIPAL='principal';
        public static function get_for_modes($modes,$contexts) { return array('SOUL.md'=>array('layer'=>'agent','priority'=>10),'USER.md'=>array('layer'=>'user','priority'=>25),'USER_MEMORY.md'=>array('layer'=>'principal','priority'=>28)); }
    }
}
namespace DataMachine\Core\FilesRepository {
    class AgentMemory {
        public function __construct(public int $user,public int $agent,public string $file,public string $layer) {}
        public function get_all() { return array('success'=>true,'content'=>$this->layer.':'.$this->user.':'.$this->file); }
    }
}
namespace DataMachine\Core\Agents {
    class AgentIdentityResolver { public function resolve_agent_identity($slug) { return (object) array('owner_id'=>1); } }
}
namespace {
    class WP_Agent { public function get_meta() { return array('datamachine_agent_id'=>7); } }
    function wp_get_agent($slug) { return new WP_Agent(); }
    function get_user_by($field,$id) { return $id === 1 || $id === 2 ? (object) array('ID'=>$id) : false; }
    function user_can($user,$cap) { return $user->ID===2; }
    function apply_filters($name,$value,...$args) { return $value; }
    function wp_json_encode($value) { return json_encode($value); }
    function resolve_context($request) {
        $args=array(base64_encode(json_encode($request)));
        ob_start(); include __DIR__.'/../bridges/roadie/roadie-plugins/wordpress-context.php'; return json_decode(ob_get_clean(),true);
    }
    $base=array('operation'=>'context','agent_slug'=>'franklin');
    $shared=resolve_context($base+array('event'=>'session_start','user_id'=>1));
    if (array_column($shared['sections'],'content')!==array('agent:0:SOUL.md')) throw new \RuntimeException('Pinned context contains user memory');
    foreach (array(1,2) as $id) {
        $turn=resolve_context($base+array('event'=>'turn','user_id'=>$id));
        $content=array_column($turn['sections'],'content');
        if (!in_array('user:'.$id.':USER.md',$content,true)||!in_array('principal:'.$id.':USER_MEMORY.md',$content,true)||in_array('agent:0:SOUL.md',$content,true)) throw new \RuntimeException('Wrong speaker/layer');
    }
    if(resolve_context($base+array('event'=>'turn','user_id'=>999))['sections']!==array()) throw new \RuntimeException('Unknown user inherited owner context');
    echo "PASS: shared/user/principal memory separation and missing-user rejection\n";
}
