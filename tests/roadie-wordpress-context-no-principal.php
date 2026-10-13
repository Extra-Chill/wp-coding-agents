<?php
// Data Machine before 0.175.5 has no LAYER_PRINCIPAL. The resolver must not
// fatal on those installs: user memory still resolves per speaker.
namespace DataMachine\Engine\AI {
    class MemoryFileRegistry {
        const MODE_ALL='all', INJECTION_AGENT_IDENTITY='identity', INJECTION_AGENT_MEMORY='memory', INJECTION_USER_PROFILE='user', LAYER_SHARED='shared', LAYER_AGENT='agent', LAYER_USER='user';
        public static function get_for_modes($modes,$contexts) { return array('RULES.md'=>array('layer'=>'shared','priority'=>5),'SOUL.md'=>array('layer'=>'agent','priority'=>10),'USER.md'=>array('layer'=>'user','priority'=>25)); }
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
namespace DataMachine\Core\Database\Agents {
    class AgentAccess { public function user_can_access($agent_id,$user_id,$role) { return false; } }
}
namespace {
    class WP_Agent { public function get_meta() { return array('datamachine_agent_id'=>7); } }
    function wp_get_agent($slug) { return new WP_Agent(); }
    function get_user_by($field,$id) { return $id===1 ? (object) array('ID'=>1) : false; }
    function user_can($user,$cap) { return false; }
    function apply_filters($name,$value,...$args) { return $value; }
    function wp_json_encode($value) { return json_encode($value); }
    function resolve_context($request) {
        $args=array(base64_encode(json_encode($request)));
        ob_start(); include __DIR__.'/../bridges/roadie/roadie-plugins/wordpress-context.php'; return json_decode(ob_get_clean(),true);
    }
    $base=array('operation'=>'context','agent_slug'=>'franklin');
    $shared=resolve_context($base+array('event'=>'session_start','user_id'=>0));
    if (array_column($shared['sections'],'content')!==array('shared:0:RULES.md','agent:0:SOUL.md')) throw new \RuntimeException('Shared context wrong without principal layer: '.json_encode($shared));
    $turn=resolve_context($base+array('event'=>'turn','user_id'=>1));
    if (!in_array('user:1:USER.md',array_column($turn['sections'],'content'),true)) throw new \RuntimeException('User memory missing without principal layer: '.json_encode($turn));
    echo "no-principal fixture ok\n";
}
