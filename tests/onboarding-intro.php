<?php
namespace DataMachine\Core\Database\Agents {
 class Agents { function get_by_slug($slug) { return ['agent_id'=>9]; } }
 class AgentAccess { function get_access($id,$user) { return $GLOBALS['grant'] ? (object)['role'=>$GLOBALS['role']] : null; } }
}
namespace DataMachine\Core\Agents {
 class ChatIdentityLinks {
  static function list_links($user,$platform) { return $GLOBALS['linked'] ? [['platform'=>$platform,'actor_id'=>'123']] : []; }
  static function resolve_user_id($platform,$actor) { return 22; }
 }
}
namespace {
 define('ABSPATH', __DIR__);
 $filters=[]; $jobs=[]; $meta=[]; $claims=[]; $sent=[]; $targets=[];
 $grant=true; $linked=true; $role='viewer'; $fail=false; $capable=false;
 function add_filter($name,$fn,$priority=10,$argc=1) { $GLOBALS['filters'][$name][]=$fn; }
 function add_action(...$args) { add_filter(...$args); }
 function apply_filters($name,$value,...$args) { foreach($GLOBALS['filters'][$name]??[] as $fn) $value=$fn($value,...$args); return $value; }
 function get_option($key,$default=[]) { return $GLOBALS['targets']; }
 function wp_next_scheduled($name,$args) { return count($GLOBALS['jobs']); }
 function wp_schedule_single_event($time,$name,$args,$error) { $GLOBALS['jobs'][]=[$name,$args]; return true; }
 function get_user_meta($user,$key,$single) { return $GLOBALS['meta'][$key]??''; }
 function update_user_meta($user,$key,$value) { $GLOBALS['meta'][$key]=$value; }
 function add_option($key,$value,...$rest) { if(isset($GLOBALS['claims'][$key])) return false; $GLOBALS['claims'][$key]=$value; return true; }
 class WP_Error {}
 function is_wp_error($v) { return $v instanceof WP_Error; }
 class WpCodingAgents_Cli_Channel_Registry { static function lookup($channel) { return ['command'=>'roadie','args'=>[]]; } }
 class WpCodingAgents_Cli_Channel_Transport {
  static function execute_config($config,$input) {
   if($config['args']===['send','--help']) return ['metadata'=>['stdout'=>$GLOBALS['capable']?' --welcome-person ':'old help']];
   $GLOBALS['sent'][]=$config['args']; return $GLOBALS['fail'] ? new WP_Error : ['sent'=>true];
  }
 }
 require __DIR__.'/../templates/wp-coding-agents-onboarding.php';
 function check($condition,$message) { if(!$condition) throw new \Exception($message); }
 function reset_intro() { $GLOBALS['jobs']=[]; $GLOBALS['meta']=[]; $GLOBALS['claims']=[]; $GLOBALS['sent']=[]; }
 function grant_event() { foreach($GLOBALS['filters']['datamachine_agent_access_granted'] as $fn) $fn(9,'user',22,'viewer',null,[]); }
 function link_event() { foreach($GLOBALS['filters']['datamachine_chat_identity_linked'] as $fn) $fn(22,'discord','123',[]); }
 function work() { WpCodingAgents_Onboarding::run(22); }
 grant_event(); check(!$jobs,'no config must not queue'); work(); check(!$sent,'no config');
 $targets=['test'=>['discord'=>['cli_channel'=>'roadie','recipient'=>'456']]];
 $linked=false; grant_event(); check(count($jobs)===1 && !$sent,'async grant'); work(); check(!$sent,'no link');
 $linked=true; work(); check(count($sent)===1,'grant when linked');
 foreach(['bash:deny','edit:deny','external_directory:deny','read:*wp-config.php:deny','grep:*wp-config.php:deny'] as $rule) check(in_array($rule,$sent[0],true),$rule);
 check(in_array('123',$sent[0],true) && in_array('--user',$sent[0],true),'adds actor');
 $prompt=$sent[0][array_search('--prompt',$sent[0])+1]; check(str_contains($prompt,'<@123>') && str_contains($prompt,'/connect'),'mention and Connect');
 work(); grant_event(); link_event(); work(); check(count($sent)===1,'regrant and relink dedup');
 reset_intro(); $grant=false; link_event(); work(); check(!$sent,'no grant'); $grant=true; link_event(); work(); check(count($sent)===1,'link when granted');
 reset_intro(); $role='admin'; $capable=true; work(); check(!in_array('bash:deny',$sent[0],true),'admin'); check(in_array('--welcome-person',$sent[0],true),'capability enabled');
 reset_intro(); $role='operator'; $capable=false; $fail=true; work(); work(); check(count($sent)===1 && !$meta,'ambiguous failure retains claim');
 reset_intro(); $fail=false; $role='unknown'; work(); check(in_array('bash:deny',$sent[0],true),'unknown role fails closed'); check(!in_array('--welcome-person',$sent[0],true),'old release fallback');
 echo "onboarding intro: PASS\n";
}
